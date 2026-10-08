
$base = $PSScriptRoot
$listFolder = Join-Path $base "BatchLists"
$outputFolder = Join-Path $base "MergedBatches"
$logFolder = Join-Path $base "Logs"
$reportPath = Join-Path $base "merge_results.csv"

New-Item -ItemType Directory -Force -Path $outputFolder, $logFolder | Out-Null

# Start with 3 batches. Change to 0 for all remaining batches.
$maxBatches = 3

$lists = @(Get-ChildItem -LiteralPath $listFolder -Filter "Batch_*.txt" |
    Sort-Object Name)

$results = @()
$processed = 0

foreach ($list in $lists) {

    $batch = $list.BaseName
    $entries = @(Get-Content -LiteralPath $list.FullName |
        Where-Object { $_ -match "^file '" })

    if ($entries.Count -lt 2) {
        Write-Host "SKIP $batch : Single video or empty"
        continue
    }

    # Identify source format and codecs
    $firstLine = $entries[0]
    $source = $firstLine.Substring(6, $firstLine.Length - 7)
    $source = $source.Replace("'\''", "'")

    if (-not (Test-Path -LiteralPath $source)) {
        Write-Warning "Source missing: $source"
        continue
    }

    $probeRaw = & ffprobe -v error -show_entries `
        "stream=codec_type,codec_name" -of json -- $source

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Cannot inspect $source"
        continue
    }

    $probe = ($probeRaw -join "`n") | ConvertFrom-Json
    $videoCodec = @($probe.streams | Where-Object {
        $_.codec_type -eq "video"
    } | Select-Object -First 1)[0].codec_name

    $audioCodec = @($probe.streams | Where-Object {
        $_.codec_type -eq "audio"
    } | Select-Object -First 1)[0].codec_name

    # Choose an appropriate output container
    if ($videoCodec -eq "h264" -and
        $audioCodec -in @("aac", "mp3", $null)) {
        $extension = ".mp4"
    }
    elseif ($videoCodec -eq "mjpeg") {
        $extension = ".avi"
    }
    else {
        $extension = ".mov"
    }

    $output = Join-Path $outputFolder "$batch$extension"
    $log = Join-Path $logFolder "$batch.log"

    # Resume safely: do not overwrite existing output
    $existing = @(Get-ChildItem -LiteralPath $outputFolder `
        -Filter "$batch.*" -File)

    if ($existing.Count -gt 0) {
        Write-Host "SKIP $batch : Output already exists" -ForegroundColor Yellow
        continue
    }

    if ($maxBatches -gt 0 -and $processed -ge $maxBatches) {
        break
    }

    $processed++
    Write-Host "MERGING $batch ($($entries.Count) clips)" -ForegroundColor Cyan

    $started = Get-Date

    & ffmpeg -nostdin -n -hide_banner -loglevel warning `
        -f concat -safe 0 -i $list.FullName `
        -map 0:v:0 -map "0:a?" -c copy `
        $output 2>&1 | Out-File -FilePath $log

    $exitCode = $LASTEXITCODE
    $status = "Failed"
    $sizeGB = 0

    if ($exitCode -eq 0 -and
        (Test-Path -LiteralPath $output)) {

        $item = Get-Item -LiteralPath $output
        $sizeGB = [math]::Round($item.Length / 1GB, 2)

        $duration = & ffprobe -v error `
            -show_entries format=duration `
            -of default=noprint_wrappers=1:nokey=1 `
            -- $output

        $durationValue = 0.0
        $validDuration = [double]::TryParse(
            (($duration | Out-String).Trim()),
            [ref]$durationValue
        )

        if ($item.Length -gt 0 -and
            $validDuration -and $durationValue -gt 0) {
            $status = "Created - needs playback verification"
        }
    }

    $results += [PSCustomObject]@{
        Batch = $batch
        Clips = $entries.Count
        Status = $status
        SizeGB = $sizeGB
        Output = $output
        Log = $log
        CompletedAt = (Get-Date).ToString("s")
        ElapsedSeconds = [math]::Round(
            ((Get-Date) - $started).TotalSeconds, 1
        )
    }

    # Save results after each batch
    $results | Export-Csv $reportPath -NoTypeInformation

    Write-Host "$batch : $status ($sizeGB GiB)"
}

Write-Host ""
Write-Host "Processing finished." -ForegroundColor Green
Write-Host "Results: $reportPath"
Write-Host "Outputs: $outputFolder"
