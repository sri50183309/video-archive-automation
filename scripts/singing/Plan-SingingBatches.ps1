
# ============================================================
# PROJECT 2: SHRAVAN SINGING VIDEO ARCHIVE
# Script: Plan-SingingBatches.ps1
#
# PURPOSE:
#   Preview chronological, duration-balanced batches
#   for direct FFmpeg merging.
#
# SAFETY:
#   READ-ONLY. No conversion, deletion, or file modification.
# ============================================================

$ErrorActionPreference = "Stop"

$folder = "E:\LenovoLaptop\Personnel\Videos\IpadUpload - Copy\ShravanSingingVideo"
$manifest = Join-Path $folder "ShravanSinging_Manifest.csv"

# Batch configuration
$targetSeconds = 12 * 60
$maxClips = 5

Write-Host ""
Write-Host "========================================"
Write-Host " SHRAVAN SINGING - BATCH PLAN"
Write-Host "========================================"

# Step 1: Check prerequisites

if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw "Manifest not found: $manifest"
}

if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    throw "ffprobe is not available in PATH."
}

# Step 2: Load and validate manifest

$rows = @(
    Import-Csv -LiteralPath $manifest |
        Sort-Object { [int]$_.Sequence }
)

if ($rows.Count -ne 57) {
    throw "Expected 57 manifest entries. Found $($rows.Count)."
}

for ($i = 0; $i -lt $rows.Count; $i++) {
    $expectedSequence = $i + 1

    if ([int]$rows[$i].Sequence -ne $expectedSequence) {
        throw "Manifest sequence error at entry $expectedSequence."
    }
}

Write-Host "Manifest entries: $($rows.Count)"
Write-Host "Target batch duration: 12 minutes"
Write-Host "Maximum clips per batch: $maxClips"
Write-Host ""

# Step 3: Probe source durations

$durations = @(
    foreach ($row in $rows) {

        if (-not (Test-Path -LiteralPath $row.SourcePath -PathType Leaf)) {
            throw "Missing source: $($row.SourcePath)"
        }

        $durationText = & ffprobe `
            -v error `
            -show_entries format=duration `
            -of default=noprint_wrappers=1:nokey=1 `
            $row.SourcePath

        if ($LASTEXITCODE -ne 0) {
            throw "Duration probe failed: $($row.FileName)"
        }

        $seconds = [double]::Parse(
            $durationText.Trim(),
            [System.Globalization.CultureInfo]::InvariantCulture
        )

        if ($seconds -le 0) {
            throw "Invalid duration: $($row.FileName)"
        }

        [pscustomobject]@{
            Sequence = [int]$row.Sequence
            FileName = $row.FileName
            Seconds  = $seconds
        }
    }
)

# Step 4: Build chronological batches

$batches = @()
$current = @()
$currentSeconds = 0.0

foreach ($item in $durations) {

    $exceedsDuration = (
        $current.Count -gt 0 -and
        ($currentSeconds + $item.Seconds) -gt $targetSeconds
    )

    $exceedsClipCount = (
        $current.Count -ge $maxClips
    )

    if ($exceedsDuration -or $exceedsClipCount) {

        $batches += ,@($current)

        $current = @()
        $currentSeconds = 0.0
    }

    $current += $item
    $currentSeconds += $item.Seconds
}

if ($current.Count -gt 0) {
    $batches += ,@($current)
}

# Step 5: Generate summary

$batchSummary = @(
    for ($i = 0; $i -lt $batches.Count; $i++) {

        $batch = @($batches[$i])

        $totalSeconds = (
            $batch |
                Measure-Object -Property Seconds -Sum
        ).Sum

        [pscustomobject]@{
            Batch   = "Batch_{0:D2}" -f ($i + 1)
            First   = $batch[0].Sequence
            Last    = $batch[-1].Sequence
            Clips   = $batch.Count
            Minutes = [math]::Round($totalSeconds / 60, 2)
        }
    }
)

# Step 6: Validate batch coverage

$totalClips = (
    $batchSummary |
        Measure-Object -Property Clips -Sum
).Sum

if ($totalClips -ne 57) {
    throw "Batch coverage failed. Expected 57, found $totalClips."
}

$plannedSequences = @(
    foreach ($batch in $batches) {
        foreach ($item in $batch) {
            $item.Sequence
        }
    }
)

for ($i = 0; $i -lt 57; $i++) {
    if ($plannedSequences[$i] -ne ($i + 1)) {
        throw "Chronological coverage error at sequence $($i + 1)."
    }
}

# Step 7: Display results

Write-Host "=== PROPOSED BATCH PLAN ==="
Write-Host ""

$batchSummary | Format-Table -AutoSize

$totalMinutes = (
    $durations |
        Measure-Object -Property Seconds -Sum
).Sum / 60

Write-Host "TOTAL BATCHES: $($batchSummary.Count)"
Write-Host "TOTAL CLIPS: $totalClips"
Write-Host "TOTAL MINUTES: $([math]::Round($totalMinutes, 2))"
Write-Host ""
Write-Host "BATCH COVERAGE: PASS"
Write-Host "CHRONOLOGICAL ORDER: PASS"
Write-Host "READ-ONLY PREVIEW: COMPLETE"
Write-Host ""
Write-Host "No videos were converted or modified."
