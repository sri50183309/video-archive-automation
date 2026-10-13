# Reusable, manifest-driven grouped video archive. Windows PowerShell 5.1+.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Prepare','RunAll')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$SourceFolder,
    [switch]$ApprovePlan,
    [switch]$Quiet,
    [int]$TargetMinutes=12,
    [int]$MaxClips=5,
    [int]$CooldownSeconds=30
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($TargetMinutes -lt 1 -or $MaxClips -lt 1 -or $CooldownSeconds -lt 0) { throw 'Invalid batching parameters.' }
$root=(Resolve-Path -LiteralPath $SourceFolder -ErrorAction Stop).ProviderPath
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'SourceFolder must be a directory.' }
foreach($tool in @('ffmpeg','ffprobe')) { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found in PATH." } }
$work=Join-Path $root 'Archive_Work'; $manifestFile=Join-Path $work 'Manifest.csv'; $planFile=Join-Path $work 'GroupPlan.csv'; $settingsFile=Join-Path $work 'Settings.json'; $outFolder=Join-Path $work 'GroupedVideos'; $logFolder=Join-Path $work 'Logs'
$extensions=@('.mp4','.mov','.m4v','.mkv','.avi','.wmv','.3gp','.mts','.m2ts','.mpeg','.mpg','.mod','.vob','.webm','.ts')
function Probe([string]$path) {
    $raw= & ffprobe -v error -show_entries 'format=duration:stream=index,codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels' -of json $path
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed: $path" }
    $p=($raw -join "`n") | ConvertFrom-Json
    if (-not $p.format.duration) { throw "No duration: $path" }
    return $p
}
function Duration([object]$p) { return [double]::Parse([string]$p.format.duration,[Globalization.CultureInfo]::InvariantCulture) }
function FileDate([string]$name,[datetime]$fallback) {
    if ($name -match '(?<!\d)(20\d{2})[-_]?([01]\d)[-_]?([0-3]\d)(?!\d)') {
        try { return [pscustomobject]@{Date=[datetime]::new([int]$Matches[1],[int]$Matches[2],[int]$Matches[3]);Source='Filename'} } catch {}
    }
    return [pscustomobject]@{Date=$fallback;Source='LastWriteTime'}
}
function BuildGroups([object[]]$rows,[int]$limitSeconds,[int]$limitClips) {
    $groups=[Collections.Generic.List[object]]::new(); $current=[Collections.Generic.List[object]]::new(); $seconds=0.0
    foreach($r in $rows) {
        $s=[double]::Parse([string]$r.Seconds,[Globalization.CultureInfo]::InvariantCulture)
        if ($current.Count -gt 0 -and (($seconds+$s -gt $limitSeconds) -or ($current.Count -ge $limitClips))) {
            $groups.Add(@($current.ToArray())); $current.Clear(); $seconds=0.0
        }
        $current.Add($r); $seconds+=$s
    }
    if ($current.Count -gt 0) { $groups.Add(@($current.ToArray())) }
    return ,$groups.ToArray()
}
function ValidateOutput([string]$path,[double]$expected) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Output missing: $path" }
    if ((Get-Item -LiteralPath $path).Length -le 0) { throw "Empty output: $path" }
    $p=Probe $path; $v=@($p.streams | Where-Object codec_type -eq 'video'); $a=@($p.streams | Where-Object codec_type -eq 'audio')
    if ($v.Count -ne 1 -or $a.Count -ne 1) { throw "Unexpected stream count: $path" }
    if ($v[0].codec_name -ne 'h264' -or $v[0].width -ne 1920 -or $v[0].height -ne 1080 -or $v[0].r_frame_rate -ne '30/1') { throw "Video format mismatch: $path" }
    if ($a[0].codec_name -ne 'aac' -or [int]$a[0].sample_rate -ne 48000 -or [int]$a[0].channels -ne 2) { throw "Audio format mismatch: $path" }
    $actual=Duration $p
    $tolerance=[math]::Max(2.0,0.015*$expected)
    if ([math]::Abs($actual-$expected) -gt $tolerance) { throw "Duration mismatch: expected $expected, actual $actual ($path)" }
    & ffmpeg -hide_banner -nostdin -v error -xerror -i $path -map '0:v:0' -map '0:a:0' -f null NUL
    if ($LASTEXITCODE -ne 0) { throw "Full decode failed: $path" }
}
if ($Mode -eq 'Prepare') {
    if (Test-Path -LiteralPath $settingsFile) { throw "Existing plan detected at $work. To protect approved work, do not overwrite it; use RunAll or archive the existing Archive_Work first." }
    $files=@(Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object { $_.FullName -notlike "$work*" -and $extensions -contains $_.Extension.ToLowerInvariant() })
    if ($files.Count -eq 0) { throw 'No supported videos found.' }
    $inventory=[Collections.Generic.List[object]]::new(); $seen=@{}; $dups=[Collections.Generic.List[object]]::new()
    foreach($f in $files) {
        $date=FileDate $f.Name $f.LastWriteTime
        $inventory.Add([pscustomobject]@{Date=$date.Date;DateSource=$date.Source;Name=$f.Name;Path=$f.FullName;Bytes=$f.Length;Hash=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash})
    }
    $sorted=@($inventory | Sort-Object Date,Name,Path)
    $rows=[Collections.Generic.List[object]]::new()
    foreach($f in $sorted) {
        if ($seen.ContainsKey($f.Hash)) { $dups.Add([pscustomobject]@{DuplicatePath=$f.Path;KeptPath=$seen[$f.Hash];SHA256=$f.Hash}); continue }
        $seen[$f.Hash]=$f.Path
        $p=Probe $f.Path; $v=@($p.streams | Where-Object codec_type -eq 'video'); $a=@($p.streams | Where-Object codec_type -eq 'audio')
        if ($v.Count -lt 1) { throw "Recording lacks video: $($f.Path). No plan saved." }
        $seconds=Duration $p
        if ($seconds -le 0) { throw "Invalid duration: $($f.Path)" }
        $rows.Add([pscustomobject]@{Sequence=$rows.Count+1;Date=$f.Date.ToString('yyyy-MM-dd HH:mm:ss');DateSource=$f.DateSource;FileName=$f.Name;SourcePath=$f.Path;SHA256=$f.Hash;HasAudio=($a.Count -gt 0);Seconds=$seconds.ToString('F6',[Globalization.CultureInfo]::InvariantCulture)})
    }
    $groups=BuildGroups @($rows.ToArray()) ($TargetMinutes*60) $MaxClips
    $plan=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $groups.Count;$i++) {
        $g=@($groups[$i]); $sum=0.0
        foreach($r in $g) { $sum += [double]::Parse($r.Seconds,[Globalization.CultureInfo]::InvariantCulture) }
        $plan.Add([pscustomobject]@{Group=$i+1;First=[int]$g[0].Sequence;Last=[int]$g[-1].Sequence;Clips=$g.Count;Seconds=$sum.ToString('F6',[Globalization.CultureInfo]::InvariantCulture);Output=('Archive_Group_{0:D3}.mp4' -f ($i+1))})
    }
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $rows | Export-Csv -LiteralPath $manifestFile -NoTypeInformation -Encoding UTF8
    $plan | Export-Csv -LiteralPath $planFile -NoTypeInformation -Encoding UTF8
    @($dups.ToArray()) | Export-Csv -LiteralPath (Join-Path $work 'Duplicates.csv') -NoTypeInformation -Encoding UTF8
    $settings=[pscustomobject]@{Version=2;TargetMinutes=$TargetMinutes;MaxClips=$MaxClips;CooldownSeconds=$CooldownSeconds;ManifestHash=(Get-FileHash $manifestFile -Algorithm SHA256).Hash;PlanHash=(Get-FileHash $planFile -Algorithm SHA256).Hash;UniqueCount=$rows.Count;GroupCount=$plan.Count}
    $settings | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8
    Write-Host "`nPREPARED: $($files.Count) files; $($rows.Count) unique; $($dups.Count) exact duplicates; $($plan.Count) groups"`n    Write-Host "Silent recordings (synthetic silence during merge): $(@($rows | Where-Object HasAudio -eq $false).Count)"
    $plan | Select-Object Group,First,Last,Clips,@{N='Minutes';E={[math]::Round(([double]::Parse($_.Seconds,[Globalization.CultureInfo]::InvariantCulture)/60),2)}},Output | Format-Table -AutoSize
    Write-Host "Manifest: $manifestFile`nPlan: $planFile`nDuplicate report: $(Join-Path $work 'Duplicates.csv')"
    Write-Host 'Review the plan and source dates. RunAll requires -ApprovePlan.'
    exit 0
}
if (-not $ApprovePlan) { throw 'RunAll requires explicit -ApprovePlan after reviewing the Prepare summary.' }
if (-not (Test-Path -LiteralPath $settingsFile)) { throw 'Prepare must run first.' }
$s=Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
if ($s.Version -ne 2) { throw 'Unsupported plan version. Re-prepare using this version.' }
if ((Get-FileHash $manifestFile -Algorithm SHA256).Hash -ne $s.ManifestHash -or (Get-FileHash $planFile -Algorithm SHA256).Hash -ne $s.PlanHash) { throw 'Manifest or group plan changed after preparation.' }
$rows=@(Import-Csv -LiteralPath $manifestFile); $plan=@(Import-Csv -LiteralPath $planFile)
if ($rows.Count -ne [int]$s.UniqueCount -or $plan.Count -ne [int]$s.GroupCount) { throw 'Plan count mismatch.' }
$groups=BuildGroups $rows ([int]$s.TargetMinutes*60) ([int]$s.MaxClips)
if ($groups.Count -ne $plan.Count) { throw 'Regenerated group count differs.' }
for($i=0;$i -lt $rows.Count;$i++) { if ([int]$rows[$i].Sequence -ne $i+1) { throw 'Manifest sequence mismatch.' } }
for($i=0;$i -lt $plan.Count;$i++) {
    $g=@($groups[$i]); $p=$plan[$i]
    if ([int]$p.Group -ne $i+1 -or [int]$p.First -ne [int]$g[0].Sequence -or [int]$p.Last -ne [int]$g[-1].Sequence -or [int]$p.Clips -ne $g.Count -or $p.Output -ne ('Archive_Group_{0:D3}.mp4' -f ($i+1))) { throw "Group plan mismatch at $($i+1)" }
}
New-Item -ItemType Directory -Force -Path $outFolder,$logFolder | Out-Null
$results=[Collections.Generic.List[object]]::new(); $failed=0
try {
    for($i=0;$i -lt $groups.Count;$i++) {
        $g=@($groups[$i]); $p=$plan[$i]; $output=Join-Path $outFolder $p.Output; $partial=Join-Path $outFolder ($p.Output -replace '\.mp4$','.partial.mp4'); $status='FAILED'; $details=''
        try {
            $expected=[double]::Parse($p.Seconds,[Globalization.CultureInfo]::InvariantCulture)
            foreach($r in $g) {
                if (-not (Test-Path -LiteralPath $r.SourcePath -PathType Leaf)) { throw "Source missing: $($r.SourcePath)" }
                if ((Get-FileHash -LiteralPath $r.SourcePath -Algorithm SHA256).Hash -ne $r.SHA256) { throw "Source hash mismatch: $($r.SourcePath)" }
            }
            if (Test-Path -LiteralPath $output) {
                ValidateOutput $output $expected
                $status='REVALIDATED'; $details='Existing output passed metadata, duration and full decode'
            } else {
                if (Test-Path -LiteralPath $partial) { throw "Partial output exists; inspect or remove before retry: $partial" }
                $argsList=[Collections.Generic.List[string]]::new()
                foreach($r in $g) { $argsList.Add('-i');$argsList.Add($r.SourcePath) }
                # Additional lavfi inputs are appended after all real recordings.
                # Each silent input is duration-limited to its corresponding source video.
                $silentInputIndex=@{}
                $nextInput=$g.Count
                for($j=0;$j -lt $g.Count;$j++) {
                    if ([string]$g[$j].HasAudio -eq 'False') {
                        $durationText=[string]$g[$j].Seconds
                        $argsList.Add('-f'); $argsList.Add('lavfi')
                        $argsList.Add('-t'); $argsList.Add($durationText)
                        $argsList.Add('-i'); $argsList.Add('anullsrc=r=48000:cl=stereo')
                        $silentInputIndex[$j]=$nextInput
                        $nextInput++
                    }
                }
                $filters=[Collections.Generic.List[string]]::new(); $inputs=''
                for($j=0;$j -lt $g.Count;$j++) {
                    $filters.Add("[$($j):v:0]fps=30,scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,setsar=1,format=yuv420p,setpts=PTS-STARTPTS[v$j]")
                    $audioIndex=$j
                    if ($silentInputIndex.ContainsKey($j)) { $audioIndex=$silentInputIndex[$j] }
                    $filters.Add("[$($audioIndex):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,asetpts=PTS-STARTPTS[a$j]")
                    $inputs += "[v$j][a$j]"
                }
                $filters.Add("${inputs}concat=n=$($g.Count):v=1:a=1[v][a]")
                $argsList.Add('-filter_complex'); $argsList.Add(($filters -join ';'))
                foreach($arg in @('-map','[v]','-map','[a]','-c:v','libx264','-preset','fast','-crf','20','-c:a','aac','-b:a','256k','-ar','48000','-ac','2','-movflags','+faststart','-n',$partial)) { $argsList.Add($arg) }
                Write-Host "Encoding group $($i+1)/$($groups.Count) ($($g.Count) recordings)"
                if ($Quiet) {
                    $argsList.Insert(0, '-nostats')
                    $argsList.Insert(0, 'error')
                    $argsList.Insert(0, '-loglevel')
                }
                & ffmpeg -hide_banner -nostdin @($argsList.ToArray())
                if ($LASTEXITCODE -ne 0) { throw "ffmpeg encoding failed: $LASTEXITCODE" }
                ValidateOutput $partial $expected
                Move-Item -LiteralPath $partial -Destination $output -ErrorAction Stop
                $status='VALIDATED'; $details='Encoded, validated, promoted from partial'
            }
            Write-Host "Group $($i+1): $status"
        } catch {
            $failed++; $details=$_.Exception.Message
            Write-Warning "Group $($i+1) FAILED: $details"
        }
        $results.Add([pscustomobject]@{Group=$i+1;First=$p.First;Last=$p.Last;Status=$status;Output=$output;Details=$details})
        if ($i -lt $groups.Count-1 -and [int]$s.CooldownSeconds -gt 0) { Start-Sleep -Seconds ([int]$s.CooldownSeconds) }
    }
} finally {
    $log=Join-Path $logFolder ('Run_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    $results | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
    Write-Host "`n=== RUN SUMMARY ==="; $results | Format-Table Group,Status,Details -AutoSize
    Write-Host "Log: $log`nOriginal recordings were not modified."
}
if ($failed -gt 0) { throw "$failed group(s) failed. Inspect log and partial outputs; do not consider archive complete." }
Write-Host "ALL $($groups.Count) GROUPS VALIDATED. Manual spot-check recommended."
