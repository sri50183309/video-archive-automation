
# Export-VideoBatchLists.ps1
# Phase 3A: Convert a validated CSV batch plan to FFmpeg lists.
# Does not execute FFmpeg or modify original videos.
#
# Usage:
# .\Export-VideoBatchLists.ps1 -Batch Batch_001
# .\Export-VideoBatchLists.ps1 -Batch Batch_001 -Force

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^Batch_\d+$')]
    [string]$Batch,

    [string]$PlanPath = (
        Join-Path $PSScriptRoot "BatchPlan\batch_plan.csv"
    ),

    [string]$OutputRoot = (
        Join-Path $PSScriptRoot "BatchLists"
    ),

    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    throw "Batch plan not found: $PlanPath"
}

$plan = @(Import-Csv -LiteralPath $PlanPath)

$rows = @(
    $plan |
        Where-Object { $_.BatchId -eq $Batch } |
        Sort-Object { [int]$_.Sequence }
)

if ($rows.Count -eq 0) {
    throw "Batch not found in plan: $Batch"
}

# Validate everything before creating an output.
$sequences = @($rows | ForEach-Object { [int]$_.Sequence })

for ($i = 0; $i -lt $sequences.Count; $i++) {
    if ($sequences[$i] -ne ($i + 1)) {
        throw "Invalid or duplicate sequence in $Batch"
    }
}

$folders = @($rows | Select-Object -ExpandProperty RelativeFolder -Unique)

if ($folders.Count -ne 1) {
    throw "Batch contains files from multiple source folders."
}

$paths = @($rows | ForEach-Object { $_.FullPath })

if (@($paths | Select-Object -Unique).Count -ne $paths.Count) {
    throw "Batch contains duplicate source paths."
}

foreach ($path in $paths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing source video: $path"
    }
}

# Existing executor expects BatchLists\Batch_NNN.txt.
$outputPath = Join-Path $OutputRoot "$Batch.txt"

if ((Test-Path -LiteralPath $outputPath) -and -not $Force) {
    throw "List already exists: $outputPath. Use -Force only after reviewing it."
}

# FFmpeg concat demuxer format.
# Escape apostrophes in file paths.
$lines = foreach ($path in $paths) {
    "file '" + $path.Replace("'", "'\''") + "'"
}

New-Item -ItemType Directory -Path $OutputRoot -Force |
    Out-Null

# Write UTF-8 without BOM for FFmpeg compatibility.
$utf8 = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllLines(
    $outputPath,
    [string[]]$lines,
    $utf8
)

Write-Host ""
Write-Host "BATCH LIST EXPORTED" -ForegroundColor Green
Write-Host "Batch         : $Batch"
Write-Host "Source folder : $($folders[0])"
Write-Host "Video count   : $($rows.Count)"
Write-Host "Output        : $outputPath"
Write-Host ""
Write-Host "No videos were modified." -ForegroundColor Cyan
