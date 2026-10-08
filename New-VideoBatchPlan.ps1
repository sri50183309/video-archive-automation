
# New-VideoBatchPlan.ps1
# Phase 2: Plan video archive batches without processing videos.
# Requires PowerShell 5.1+
#
# Example:
# .\New-VideoBatchPlan.ps1
# .\New-VideoBatchPlan.ps1 -TargetSizeGB 4.5

param(
    [string]$InventoryPath = (
        Join-Path $PSScriptRoot "InventoryReports\video_inventory.csv"
    ),

    [string]$OutputRoot = (
        Join-Path $PSScriptRoot "BatchPlan"
    ),

    [double]$TargetSizeGB = 4.5
)

$ErrorActionPreference = "Stop"

if ($TargetSizeGB -le 0) {
    throw "TargetSizeGB must be greater than zero."
}

if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
    throw "Inventory not found: $InventoryPath"
}

$videos = @(Import-Csv -LiteralPath $InventoryPath)

if ($videos.Count -eq 0) {
    throw "Inventory contains no videos."
}

# Accept either Phase 1 column naming convention.
$columns = @($videos[0].PSObject.Properties.Name)

$folderColumn = if ($columns -contains "RelativeFolder") {
    "RelativeFolder"
}
elseif ($columns -contains "SourceFolder") {
    "SourceFolder"
}
else {
    throw "Inventory needs RelativeFolder or SourceFolder."
}

$sizeColumn = if ($columns -contains "SizeBytes") {
    "SizeBytes"
}
else {
    throw "Inventory needs SizeBytes."
}

$pathColumn = if ($columns -contains "FullPath") {
    "FullPath"
}
else {
    throw "Inventory needs FullPath."
}

$targetBytes = [long]($TargetSizeGB * 1GB)

# We do not touch source videos.
New-Item -ItemType Directory -Path $OutputRoot -Force |
    Out-Null

$plan = New-Object System.Collections.Generic.List[object]
$summary = New-Object System.Collections.Generic.List[object]

$batchNumber = 0

# Folder boundaries are preserved.
$folderGroups = @(
    $videos |
        Where-Object {
            $_.Status -eq "OK" -and
            [long]$_.($sizeColumn) -gt 0
        } |
        Group-Object -Property $folderColumn |
        Sort-Object Name
)

foreach ($folderGroup in $folderGroups) {

    $folderName = $folderGroup.Name

    # Deterministic ordering by relative path.
    $folderVideos = @(
        $folderGroup.Group |
            Sort-Object RelativePath, FullPath
    )

    $currentBatch = New-Object System.Collections.Generic.List[object]
    $currentBytes = [long]0

    foreach ($video in $folderVideos) {

        $videoBytes = [long]$video.($sizeColumn)

        # Flush current batch if next clip exceeds target.
        if (
            $currentBatch.Count -gt 0 -and
            ($currentBytes + $videoBytes) -gt $targetBytes
        ) {
            $batchNumber++

            $batchId = "Batch_{0:D3}" -f $batchNumber

            $position = 0

            foreach ($item in $currentBatch) {
                $position++

                $plan.Add([pscustomobject]@{
                    BatchId         = $batchId
                    RelativeFolder  = $folderName
                    Sequence        = $position
                    RelativePath    = $item.RelativePath
                    FullPath        = $item.($pathColumn)
                    SizeBytes       = [long]$item.($sizeColumn)
                    PlannedMethod   = "Normalize"
                    Note            = ""
                })
            }

            $summary.Add([pscustomobject]@{
                BatchId          = $batchId
                RelativeFolder   = $folderName
                VideoCount       = $currentBatch.Count
                SourceSizeGiB    = [Math]::Round(
                    $currentBytes / 1GB, 3
                )
                TargetSizeGiB    = $TargetSizeGB
                PlannedMethod    = "Normalize"
                Status           = "PLANNED"
            })

            $currentBatch.Clear()
            $currentBytes = [long]0
        }

        # Oversized source clips get their own batch.
        $currentBatch.Add($video)
        $currentBytes += $videoBytes
    }

    # Flush final batch for this source folder.
    if ($currentBatch.Count -gt 0) {

        $batchNumber++

        $batchId = "Batch_{0:D3}" -f $batchNumber

        $position = 0

        foreach ($item in $currentBatch) {
            $position++

            $note = if (
                [long]$item.($sizeColumn) -gt $targetBytes
            ) {
                "Source exceeds target; review after encoding"
            }
            else {
                ""
            }

            $plan.Add([pscustomobject]@{
                BatchId         = $batchId
                RelativeFolder  = $folderName
                Sequence        = $position
                RelativePath    = $item.RelativePath
                FullPath        = $item.($pathColumn)
                SizeBytes       = [long]$item.($sizeColumn)
                PlannedMethod   = "Normalize"
                Note            = $note
            })
        }

        $summary.Add([pscustomobject]@{
            BatchId          = $batchId
            RelativeFolder   = $folderName
            VideoCount       = $currentBatch.Count
            SourceSizeGiB    = [Math]::Round(
                $currentBytes / 1GB, 3
            )
            TargetSizeGiB    = $TargetSizeGB
            PlannedMethod    = "Normalize"
            Status           = if ($currentBytes -gt $targetBytes) {
                "OVERSIZED_SOURCE"
            }
            else {
                "PLANNED"
            }
        })
    }
}

$planPath = Join-Path $OutputRoot "batch_plan.csv"
$summaryPath = Join-Path $OutputRoot "batch_summary.csv"

$plan |
    Export-Csv -LiteralPath $planPath `
        -NoTypeInformation -Encoding UTF8

$summary |
    Export-Csv -LiteralPath $summaryPath `
        -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "PHASE 2 - BATCH PLAN COMPLETE" -ForegroundColor Green
Write-Host "Source folders : $($folderGroups.Count)"
Write-Host "Videos planned : $($plan.Count)"
Write-Host "Batches created: $($summary.Count)"
Write-Host "Target size    : $TargetSizeGB GiB"
Write-Host ""
Write-Host "Plan   : $planPath"
Write-Host "Summary: $summaryPath"
Write-Host ""
Write-Host "DRY RUN: No videos were modified." -ForegroundColor Cyan
