
param(
    [ValidateSet("Preview", "Batch", "All")]
    [string]$Mode = "Preview",

    [ValidateRange(1, 99)]
    [int]$BatchNumber = 1
)

$ErrorActionPreference = "Stop"

$root = "E:\LenovoLaptop\Personnel\Videos\IpadUpload - Copy\ShravanSingingVideo"
$manifestPath = Join-Path $root "ShravanSinging_Manifest.csv"
$segmentFolder = Join-Path $root "DirectMerge_Segments"
$logFolder = Join-Path $root "DirectMerge_Logs"

$targetSeconds = 720
$maxClips = 5

function Get-DurationSeconds {
    param([string]$Path)

    $result = & ffprobe -v error `
        -show_entries format=duration `
        -of default=noprint_wrappers=1:nokey=1 `
        $Path

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        throw "Cannot read duration: $Path"
    }

    return [double]::Parse(
        $result.Trim(),
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-VideoBatch {
    param([object[]]$Items)

    $batches = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[object]]::new()
    $seconds = 0.0

    foreach ($item in $Items) {
        if ($current.Count -gt 0 -and (
            ($seconds + $item.Seconds -gt $targetSeconds) -or
            ($current.Count -ge $maxClips)
        )) {
            $batches.Add(@($current.ToArray()))
            $current.Clear()
            $seconds = 0.0
        }

        $current.Add($item)
        $seconds += $item.Seconds
    }

    if ($current.Count -gt 0) {
        $batches.Add(@($current.ToArray()))
    }

    return $batches.ToArray()
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest missing: $manifestPath"
}

foreach ($tool in @("ffmpeg", "ffprobe")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not available."
    }
}

$manifest = @(
    Import-Csv -LiteralPath $manifestPath |
        Sort-Object { [int]$_.Sequence }
)

if ($manifest.Count -ne 57) {
    throw "Expected 57 manifest entries, found $($manifest.Count)."
}

$items = @(
    for ($i = 0; $i -lt $manifest.Count; $i++) {
        $row = $manifest[$i]

        if ([int]$row.Sequence -ne ($i + 1)) {
            throw "Manifest sequence error at $($i + 1)"
        }

        if (-not (Test-Path -LiteralPath $row.SourcePath -PathType Leaf)) {
            throw "Missing source: $($row.SourcePath)"
        }

        [pscustomobject]@{
            Sequence = [int]$row.Sequence
            FileName = $row.FileName
            SourcePath = $row.SourcePath
            SHA256 = $row.SHA256
            Seconds = Get-DurationSeconds -Path $row.SourcePath
        }
    }
)

$batches = @(
    Get-VideoBatch -Items $items
)

Write-Host ""
Write-Host "SHRAVAN SINGING ARCHIVE"
Write-Host "Mode: $Mode"
Write-Host "Batches: $($batches.Count)"
Write-Host "Sources: $($items.Count)"
Write-Host ""

$summary = @(
    for ($i = 0; $i -lt $batches.Count; $i++) {
        $batch = @($batches[$i])
        [pscustomobject]@{
            Batch = $i + 1
            First = $batch[0].Sequence
            Last = $batch[-1].Sequence
            Clips = $batch.Count
            Minutes = [math]::Round(
                ($batch | Measure-Object Seconds -Sum).Sum / 60, 2
            )
        }
    }
)

$summary | Format-Table -AutoSize

if ($Mode -eq "Preview") {
    Write-Host "PREVIEW COMPLETE - No files created."
    exit 0
}

if ($batches.Count -ne 13) {
    throw "Batch plan changed. Expected 13 batches."
}

if ($Mode -eq "Batch" -and $BatchNumber -gt $batches.Count) {
    throw "Batch number exceeds available batches."
}

New-Item -ItemType Directory -Force -Path $segmentFolder | Out-Null
New-Item -ItemType Directory -Force -Path $logFolder | Out-Null

$selected = if ($Mode -eq "Batch") {
    @($BatchNumber)
} else {
    @(1..$batches.Count)
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($batchId in $selected) {
    $batch = @($batches[$batchId - 1])
    $name = "Singing_Batch_{0:D2}.mp4" -f $batchId
    $output = Join-Path $segmentFolder $name
    $status = "FAILED"
    $details = ""

    try {
        if (Test-Path -LiteralPath $output) {
            $status = "EXISTS_NEEDS_VALIDATION"
            $details = "Existing output not overwritten"
        }
        else {
            foreach ($item in $batch) {
                $hash = (Get-FileHash -LiteralPath $item.SourcePath -Algorithm SHA256).Hash

                if ($hash -ne $item.SHA256) {
                    throw "SHA-256 mismatch: $($item.FileName)"
                }
            }

            $arguments = [System.Collections.Generic.List[string]]::new()
            $arguments.Add("-hide_banner")

            foreach ($item in $batch) {
                $arguments.Add("-i")
                $arguments.Add($item.SourcePath)
            }

            $filters = [System.Collections.Generic.List[string]]::new()
            $concatInputs = ""

            for ($j = 0; $j -lt $batch.Count; $j++) {
                $filters.Add(
                    "[$($j):v:0]fps=30,scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,setsar=1,format=yuv420p,setpts=PTS-STARTPTS[v$j]"
                )

                $filters.Add(
                    "[$($j):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,asetpts=PTS-STARTPTS[a$j]"
                )

                $concatInputs += "[v$j][a$j]"
            }

            $filters.Add(
                "${concatInputs}concat=n=$($batch.Count):v=1:a=1[v][a]"
            )

            $filterGraph = $filters -join ";"

            $arguments.Add("-filter_complex")
            $arguments.Add($filterGraph)

            foreach ($arg in @(
                "-map", "[v]",
                "-map", "[a]",
                "-c:v", "libx264",
                "-preset", "fast",
                "-crf", "20",
                "-c:a", "aac",
                "-b:a", "256k",
                "-ar", "48000",
                "-ac", "2",
                "-movflags", "+faststart",
                "-n", $output
            )) {
                $arguments.Add($arg)
            }

            Write-Host ""
            Write-Host "Processing batch $batchId / $($batches.Count)"
            Write-Host "Sources: $($batch[0].Sequence)-$($batch[-1].Sequence)"

            & ffmpeg @($arguments.ToArray())

            if ($LASTEXITCODE -ne 0) {
                throw "FFmpeg exited with code $LASTEXITCODE"
            }

            if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
                throw "Output missing after FFmpeg completed"
            }

            $status = "ENCODED_NEEDS_VALIDATION"
            $details = "FFmpeg completed; independent validation required"
        }
    }
    catch {
        $details = $_.Exception.Message
        Write-Warning "Batch $batchId failed: $details"
    }

    $results.Add([pscustomobject]@{
        Batch = $batchId
        FirstSequence = $batch[0].Sequence
        LastSequence = $batch[-1].Sequence
        Output = $output
        Status = $status
        Details = $details
    })
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $logFolder "Run_$timestamp.csv"

$results | Export-Csv -LiteralPath $logPath `
    -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "=== RUN RESULTS ==="
$results | Format-Table Batch, Status, Details -AutoSize

Write-Host "Log: $logPath"
Write-Host "Original recordings were not modified."
Write-Host "No segment is approved until separately validated."
