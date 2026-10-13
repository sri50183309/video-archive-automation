# Multi-folder orchestrator for the tested VideoArchive-v2.ps1 engine.
# Windows PowerShell 5.1+. Originals are never deleted; optional verified relocation after all folders succeed.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Prepare','RunAll')][string]$Mode,
    [Parameter(Mandatory=$true)][string[]]$Folders,
    [switch]$ApprovePlans,
    [switch]$MoveOriginalsToBeDeleted,
    [string]$EnginePath=(Join-Path $PSScriptRoot 'VideoArchive-v2.ps1'),
    [ValidateRange(0,86400)][int]$FolderCooldownSeconds=60,
    [ValidateRange(0,86400)][int]$GroupCooldownSeconds=30,
    [ValidateRange(1,1440)][int]$TargetMinutes=12,
    [ValidateRange(1,100)][int]$MaxClips=5
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($MoveOriginalsToBeDeleted -and ($Mode -ne 'RunAll' -or -not $ApprovePlans)) { throw 'Moving originals requires -Mode RunAll -ApprovePlans -MoveOriginalsToBeDeleted.' }
if ($Mode -eq 'RunAll' -and -not $ApprovePlans) { throw 'RunAll requires -ApprovePlans after reviewing each folder plan.' }
if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf)) { throw "Engine missing: $EnginePath" }
$engine=(Resolve-Path -LiteralPath $EnginePath).ProviderPath
$resolved=[Collections.Generic.List[string]]::new()
foreach($folder in $Folders) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "Folder missing: $folder" }
    $path=(Resolve-Path -LiteralPath $folder).ProviderPath.TrimEnd('\')
    if ($resolved.Contains($path)) { throw "Duplicate folder selection: $path" }
    $resolved.Add($path)
}
# Prevent nested folder selections, which could otherwise process the same source twice.
for($i=0;$i -lt $resolved.Count;$i++) {
    for($j=$i+1;$j -lt $resolved.Count;$j++) {
        if ($resolved[$i].StartsWith($resolved[$j]+'\',[StringComparison]::OrdinalIgnoreCase) -or $resolved[$j].StartsWith($resolved[$i]+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Selected folders overlap; choose independent folders.'
        }
    }
}

# Only run relocation after EVERY selected folder has completed RunAll successfully.
# Build a complete, verified move plan before moving the first source file.
function Get-MovePlan([string[]]$sourceFolders) {
    $all=[Collections.Generic.List[object]]::new()
    $destinations=@{}
    foreach($sourceRoot in $sourceFolders) {
        $work=Join-Path $sourceRoot 'Archive_Work'
        $manifest=Join-Path $work 'Manifest.csv'
        $duplicates=Join-Path $work 'Duplicates.csv'
        $settings=Join-Path $work 'Settings.json'
        $plan=Join-Path $work 'GroupPlan.csv'
        foreach($required in @($manifest,$settings,$plan)) {
            if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing archive audit file: $required" }
        }
        $s=Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
        if ([int]$s.Version -ne 2) { throw "Unsupported archive plan in $sourceRoot" }
        if ((Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash -ne $s.ManifestHash -or (Get-FileHash -LiteralPath $plan -Algorithm SHA256).Hash -ne $s.PlanHash) {
            throw "Archive plan or manifest changed: $sourceRoot"
        }
        $records=[Collections.Generic.List[object]]::new()
        foreach($r in @(Import-Csv -LiteralPath $manifest)) {
            $records.Add([pscustomobject]@{Path=$r.SourcePath;SHA256=$r.SHA256})
        }
        if (Test-Path -LiteralPath $duplicates -PathType Leaf) {
            # Empty duplicate CSVs have no records; that's fine.
            foreach($r in @(Import-Csv -LiteralPath $duplicates)) {
                if ($null -ne $r -and $r.DuplicatePath) { $records.Add([pscustomobject]@{Path=$r.DuplicatePath;SHA256=$r.SHA256}) }
            }
        }
        $holding=Join-Path $sourceRoot 'ToBeDeleted'
        $prefix=$sourceRoot.TrimEnd('\')+'\'
        $seen=@{}
        foreach($r in $records) {
            $path=[IO.Path]::GetFullPath([string]$r.Path)
            if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Manifest references a file outside its source folder: $path" }
            $relative=$path.Substring($prefix.Length)
            if ($relative.StartsWith('Archive_Work\',[StringComparison]::OrdinalIgnoreCase) -or $relative.StartsWith('ToBeDeleted\',[StringComparison]::OrdinalIgnoreCase)) {
                throw "Unexpected archive/holding path in manifest: $path"
            }
            if ($seen.ContainsKey($path)) { throw "Repeated original path in manifest/duplicates: $path" }
            $seen[$path]=$true
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Original missing; relocation not started: $path" }
            if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing to move linked file: $path" }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne [string]$r.SHA256) { throw "Original hash mismatch; relocation not started: $path" }
            $dest=Join-Path $holding $relative
            if (Test-Path -LiteralPath $dest) { throw "Destination already exists; relocation not started: $dest" }
            if ($destinations.ContainsKey($dest)) { throw "Destination collision: $dest" }
            $destinations[$dest]=$true
            $all.Add([pscustomobject]@{Folder=$sourceRoot;Source=$path;Destination=$dest;SHA256=$r.SHA256;Status='PENDING'})
        }
        $duplicateCount=0
        if (Test-Path -LiteralPath $duplicates -PathType Leaf) { $duplicateCount=@(Import-Csv -LiteralPath $duplicates | Where-Object { $null -ne $_ -and $_.DuplicatePath }).Count }
        if ($records.Count -ne ([int]$s.UniqueCount + $duplicateCount)) {
            throw "Source count mismatch: $sourceRoot"
        }
        # Detect newly added supported recordings not covered by the approved plan.
        $ext=@('.mp4','.mov','.m4v','.mkv','.avi','.wmv','.3gp')
        $actual=@(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | Where-Object {
            $_.FullName -notlike "$work\*" -and $_.FullName -notlike "$holding\*" -and $ext -contains $_.Extension.ToLowerInvariant()
        })
        if ($actual.Count -ne $records.Count) { throw "Source inventory changed since Prepare in $sourceRoot ($($actual.Count) current vs $($records.Count) planned)." }
        foreach($f in $actual) { if (-not $seen.ContainsKey($f.FullName)) { throw "Unplanned recording found: $($f.FullName)" } }
        $outFolder=Join-Path $work 'GroupedVideos'
        $groups=@(Import-Csv -LiteralPath $plan)
        foreach($g in $groups) {
            $out=Join-Path $outFolder $g.Output
            if (-not (Test-Path -LiteralPath $out -PathType Leaf)) { throw "Validated output missing: $out" }
        }
    }
    return ,$all.ToArray()
}
function Move-VerifiedOriginals([string[]]$sourceFolders) {
    $moves=@(Get-MovePlan $sourceFolders)
    if ($moves.Count -eq 0) { throw 'No original files found to relocate.' }
    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $journal=Join-Path (Join-Path $sourceFolders[0] 'Archive_Work') ("Relocation_$stamp.csv")
    Write-Host "`nVerified $($moves.Count) original files for relocation. Journal: $journal" -ForegroundColor Cyan
    # Journal is updated after each move, so an interruption remains auditable.
    $moves | Export-Csv -LiteralPath $journal -NoTypeInformation -Encoding UTF8
    try {
        foreach($m in $moves) {
            $parent=Split-Path -Parent $m.Destination
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            Move-Item -LiteralPath $m.Source -Destination $m.Destination -ErrorAction Stop
            $m.Status='MOVED'
            $moves | Export-Csv -LiteralPath $journal -NoTypeInformation -Encoding UTF8
        }
    } catch {
        $moves | Export-Csv -LiteralPath $journal -NoTypeInformation -Encoding UTF8
        throw "Relocation stopped. Some files may already be in ToBeDeleted. Review journal before retrying. $($_.Exception.Message)"
    }
    Write-Host "RELOCATED: $($moves.Count) originals into per-folder ToBeDeleted directories. Nothing deleted." -ForegroundColor Green
    Write-Host "Relocation journal: $journal"
}

$results=[Collections.Generic.List[object]]::new()
for($i=0;$i -lt $resolved.Count;$i++) {
    $folder=$resolved[$i]
    Write-Host "`n=== FOLDER $($i+1)/$($resolved.Count): $folder ===" -ForegroundColor Cyan
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,'-Mode',$Mode,'-SourceFolder',$folder)
    if ($Mode -eq 'Prepare') {
        $arguments+=@('-TargetMinutes',"$TargetMinutes",'-MaxClips',"$MaxClips",'-CooldownSeconds',"$GroupCooldownSeconds")
    } else { $arguments+='-ApprovePlan' }
    # Separate process isolates the V2 engine's 'exit 0' in Prepare mode.
    & powershell.exe @arguments
    $code=$LASTEXITCODE
    $status=if ($code -eq 0) {'SUCCESS'} else {'FAILED'}
    $results.Add([pscustomobject]@{Folder=$folder;Mode=$Mode;Status=$status;ExitCode=$code})
    if ($code -ne 0) {
        Write-Warning "Folder failed (exit code $code). Stopping before the next folder. Review logs and rerun after correction."
        break
    }
    if ($i -lt $resolved.Count-1 -and $FolderCooldownSeconds -gt 0) {
        Write-Host "Cooling down $FolderCooldownSeconds seconds before next folder..."
        Start-Sleep -Seconds $FolderCooldownSeconds
    }
}
Write-Host "`n=== MULTI-FOLDER SUMMARY ===" -ForegroundColor Cyan
$results | Format-Table Folder,Mode,Status,ExitCode -AutoSize
if (@($results | Where-Object Status -eq 'FAILED').Count -gt 0) { throw 'Multi-folder operation stopped after a failure.' }
if ($results.Count -ne $resolved.Count) { throw 'Not all selected folders completed; relocation cancelled.' }
if ($MoveOriginalsToBeDeleted) { Move-VerifiedOriginals @($resolved.ToArray()) }
else { Write-Host 'All selected folders completed. Originals remain in place (relocation not requested).' }
