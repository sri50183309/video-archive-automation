# PowerShell 5.1+ | FFmpeg and ffprobe must be on PATH.
# First test: .\Process-NormalizedVideoBatches.ps1 -Batch Batch_022
# After validation: .\Process-NormalizedVideoBatches.ps1 -All
param(
    [string]$Batch = 'Batch_022',
    [switch]$All,
    [int]$Crf = 20,
    [string]$Preset = 'medium'
)
$ErrorActionPreference = 'Stop'
$base = $PSScriptRoot
$listDir = Join-Path $base 'BatchLists'
$outDir = Join-Path $base 'NormalizedBatches'
$workDir = Join-Path $base 'NormalizedWork'
$logDir = Join-Path $base 'NormalizedLogs'
$report = Join-Path $base 'normalized_results.csv'
$timingReport = Join-Path $base 'processing_times.csv'
foreach ($dir in @($outDir,$workDir,$logDir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
foreach ($tool in @('ffmpeg','ffprobe')) { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH" } }
if ($Crf -lt 0 -or $Crf -gt 51) { throw 'CRF must be between 0 and 51' }
if ($Preset -notin @('ultrafast','superfast','veryfast','faster','fast','medium','slow','slower','veryslow')) { throw 'Invalid x264 preset' }

function Test-Video([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -lt 1024) { return $false }
    $probe = & ffprobe -v error -select_streams v:0 -show_entries 'stream=codec_name,width,height' -show_entries 'format=duration' -of json -- $Path 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    try {
        $info = ($probe -join "`n") | ConvertFrom-Json
        return ($info.streams.Count -ge 1 -and [double]$info.format.duration -gt 0)
    } catch { return $false }
}
function Write-Result([string]$Name,[string]$Status,[int]$Clips,[string]$Output,[string]$Details) {
    $row = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('s'); Batch = $Name; Status = $Status
        Clips = $Clips; Output = $Output; SizeGiB = if (Test-Path -LiteralPath $Output) { [math]::Round((Get-Item -LiteralPath $Output).Length / 1GB,3) } else { 0 }
        Details = $Details
    }
    $row | Export-Csv -LiteralPath $report -NoTypeInformation -Append
}
function Write-Timing([string]$Name,[string]$Stage,[int]$Clip,[string]$Action,[datetime]$Started,[datetime]$Finished,[string]$Status,[string]$Source,[string]$Output) {
    $row = [pscustomobject]@{
        Batch = $Name
        Stage = $Stage
        Clip = $Clip
        Action = $Action
        StartedAt = $Started.ToString('o')
        FinishedAt = $Finished.ToString('o')
        ElapsedSeconds = [math]::Round(($Finished - $Started).TotalSeconds, 2)
        Status = $Status
        Source = $Source
        Output = $Output
        SizeGiB = if ($Output -and (Test-Path -LiteralPath $Output -PathType Leaf)) {
            [math]::Round((Get-Item -LiteralPath $Output).Length / 1GB, 3)
        } else { 0 }
    }
    $row | Export-Csv -LiteralPath $timingReport -NoTypeInformation -Append
}
function Read-List([string]$Path) {
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match "^file '(.*)'\s*$") {
            $p = $Matches[1].Replace("'\''", "'")
            $paths.Add($p)
        }
    }
    return ,$paths.ToArray()
}

$lists = if ($All) {
    @(Get-ChildItem -LiteralPath $listDir -Filter 'Batch_*.txt' -File | Sort-Object Name)
} else {
    @(Get-Item -LiteralPath (Join-Path $listDir "$Batch.txt"))
}

foreach ($list in $lists) {
    $name = $list.BaseName
    $sources = Read-List $list.FullName
    if ($sources.Count -lt 2) { Write-Host "SKIP $name : fewer than 2 clips"; continue }
    $final = Join-Path $outDir "$name.mp4"
    $batchLogDir = Join-Path $logDir $name
    $batchWorkDir = Join-Path $workDir $name
    New-Item -ItemType Directory -Force -Path $batchLogDir,$batchWorkDir | Out-Null
    if (Test-Path -LiteralPath $final) {
        if (Test-Video $final) {
            Write-Host "SKIP $name : existing output (not overwritten)" -ForegroundColor Yellow
            Write-Result $name 'Skipped-existing-unverified-playback' $sources.Count $final 'Existing output left unchanged'
        } else {
            Write-Warning "$name : existing output failed basic validation. Inspect it manually."
            Write-Result $name 'Failed-existing-output' $sources.Count $final 'Existing output invalid; not overwritten'
        }
        continue
    }
    $batchStarted = Get-Date
    Write-Host "[$($batchStarted.ToString('HH:mm:ss'))] NORMALIZING $name ($($sources.Count) clips)" -ForegroundColor Cyan
    $segments = New-Object 'System.Collections.Generic.List[string]'
    $failed = $null
    for ($i = 0; $i -lt $sources.Count; $i++) {
        $src = $sources[$i]
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { $failed = "Missing source: $src"; break }
        $segment = Join-Path $batchWorkDir ('clip_{0:D4}.mp4' -f ($i+1))
        $partial = Join-Path $batchWorkDir ('clip_{0:D4}.partial.mp4' -f ($i+1))
        $log = Join-Path $batchLogDir ('clip_{0:D4}.log' -f ($i+1))
        if (Test-Path -LiteralPath $segment) {
            if (Test-Video $segment) {
                $reuseTime = Get-Date
                $segments.Add($segment)
                Write-Host "  [$($reuseTime.ToString('HH:mm:ss'))] Reuse clip $($i+1)"
                Write-Timing $name 'Clip' ($i+1) 'Reuse' $reuseTime $reuseTime 'Success' $src $segment
                continue
            }
            $failed = "Invalid cached clip: $segment (inspect/remove manually)"; break
        }
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        $probeRaw = & ffprobe -v error -show_entries 'stream=codec_type' -of json -- $src 2>$null
        if ($LASTEXITCODE -ne 0) { $failed = "Cannot probe: $src"; break }
        try {
            $probe = ($probeRaw -join "`n") | ConvertFrom-Json
            $hasAudio = @($probe.streams | Where-Object { $_.codec_type -eq 'audio' }).Count -gt 0
        } catch { $failed = "Invalid probe response: $src"; break }
        # FFmpeg auto-rotates phone footage from display-matrix metadata by default.
        # scale+pad preserves full picture; fps, SAR, codec, audio are normalized.
        $vf = 'scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=30,format=yuv420p'
        $args = @('-nostdin','-hide_banner','-y','-i',$src)
        if (-not $hasAudio) { $args += @('-f','lavfi','-i','anullsrc=channel_layout=stereo:sample_rate=48000') }
        $args += @('-map','0:v:0')
        if ($hasAudio) { $args += @('-map','0:a:0') } else { $args += @('-map','1:a:0','-shortest') }
        $args += @('-vf',$vf,'-c:v','libx264','-preset',$Preset,'-crf',"$Crf",'-r','30',
            '-video_track_timescale','30000','-c:a','aac','-b:a','160k','-ar','48000','-ac','2',
            '-af','aresample=async=1:first_pts=0','-movflags','+faststart','-f','mp4',$partial)
        $clipStarted = Get-Date
        Write-Host "  [$($clipStarted.ToString('HH:mm:ss'))] Encoding clip $($i+1)/$($sources.Count)"
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & ffmpeg @args 2> $log
            $ffmpegExitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        $clipFinished = Get-Date
        if ($ffmpegExitCode -ne 0 -or -not (Test-Video $partial)) {
            Write-Timing $name 'Clip' ($i+1) 'Encode' $clipStarted $clipFinished 'Failed' $src $partial
            $failed = "FFmpeg failed clip $($i+1): $src (see $log)"; break
        }
        Move-Item -LiteralPath $partial -Destination $segment
        $segments.Add($segment)
        Write-Timing $name 'Clip' ($i+1) 'Encode' $clipStarted $clipFinished 'Success' $src $segment
        Write-Host "  [$($clipFinished.ToString('HH:mm:ss'))] Completed clip $($i+1) in $([math]::Round(($clipFinished - $clipStarted).TotalSeconds,1)) sec"
    }
    if ($failed) {
        Write-Warning "$name : $failed"
        Write-Result $name 'Failed' $sources.Count $final $failed
        Write-Timing $name 'Batch' 0 'Process' $batchStarted (Get-Date) 'Failed' '' $final
        continue
    }
    $concatList = Join-Path $batchWorkDir 'normalized_concat.txt'
    $concatLines = foreach ($seg in $segments) { "file '" + $seg.Replace("'", "'\''") + "'" }
    [System.IO.File]::WriteAllLines($concatList, [string[]]$concatLines, (New-Object System.Text.UTF8Encoding($false)))
    $mergedPartial = Join-Path $outDir "$name.partial.mp4"
    if (Test-Path -LiteralPath $mergedPartial) { Remove-Item -LiteralPath $mergedPartial -Force }
    $mergeLog = Join-Path $batchLogDir 'merge.log'
    $mergeStarted = Get-Date
    Write-Host "[$($mergeStarted.ToString('HH:mm:ss'))] Starting final merge"
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & ffmpeg -nostdin -hide_banner -y `
            -f concat -safe 0 -i $concatList `
            -map '0:v:0' -map '0:a:0' `
            -c copy -movflags '+faststart' `
            -f mp4 $mergedPartial 2> $mergeLog
        $mergeExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    $mergeFinished = Get-Date
    if ($mergeExitCode -eq 0 -and (Test-Video $mergedPartial)) {
        Move-Item -LiteralPath $mergedPartial -Destination $final
        Write-Timing $name 'Merge' 0 'Copy' $mergeStarted $mergeFinished 'Success' $concatList $final
        Write-Host "CREATED $final" -ForegroundColor Green
        Write-Result $name 'Created-needs-playback-check' $sources.Count $final 'Review transitions, audio, orientation; confirm OneDrive backup before cleanup'
    } else {
        Write-Timing $name 'Merge' 0 'Copy' $mergeStarted $mergeFinished 'Failed' $concatList $mergedPartial
        Write-Warning "Merge failed for $name. See $mergeLog"
        Write-Result $name 'Failed-merge' $sources.Count $final "See $mergeLog"
    }
    $batchFinished = Get-Date
    $batchStatus = if (Test-Path -LiteralPath $final) { 'Created-needs-validation' } else { 'Failed' }
    Write-Timing $name 'Batch' 0 'Process' $batchStarted $batchFinished $batchStatus '' $final
    Write-Host "[$($batchFinished.ToString('HH:mm:ss'))] $name elapsed: $([math]::Round(($batchFinished - $batchStarted).TotalMinutes,1)) min"
}
Write-Host "Timing report: $timingReport"
Write-Host "Done. Report: $report" -ForegroundColor Cyan
