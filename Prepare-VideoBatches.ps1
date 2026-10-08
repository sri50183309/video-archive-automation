# Prepare compatible ~5 GiB FFmpeg batches. Does NOT merge, move, or delete sources.
$work = $PSScriptRoot
$root = Split-Path -Parent $work
$work = Join-Path $root 'VideoLists'
$lists = Join-Path $work 'BatchLists'
$output = Join-Path $work 'MergedBatches'
$maxBytes = 5GB
New-Item -ItemType Directory -Force -Path $lists, $output | Out-Null
$csv = Join-Path $work 'video_compatibility.csv'
if (-not (Test-Path -LiteralPath $csv)) { throw "Missing $csv" }
$rows = @(Import-Csv -LiteralPath $csv)
$valid = @(); $skipped = @()
foreach ($r in $rows) {
    $path = Join-Path $root $r.FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $skipped += [pscustomobject]@{FileName=$r.FileName;Reason='Source missing'}; continue
    }
    $f = Get-Item -LiteralPath $path
    if ($f.Length -gt $maxBytes) {
        $skipped += [pscustomobject]@{FileName=$r.FileName;Reason='Individual file over 5 GiB'}; continue
    }
    $signature = @($r.VideoCodec,$r.Resolution,$r.FPS,$r.PixelFormat,$r.VideoTimeBase,$r.AudioCodec,$r.AudioRate,$r.AudioChannels) -join '|'
    $valid += [pscustomobject]@{Row=$r;Path=$f.FullName;Bytes=$f.Length;Signature=$signature}
}
$manifest = @(); $batchNumber = 0
foreach ($group in ($valid | Group-Object Signature | Sort-Object Name)) {
    $current = @(); $sum = [long]0
    $items = @($group.Group | Sort-Object Path)
    foreach ($item in $items) {
        if ($current.Count -gt 0 -and ($sum + $item.Bytes) -gt $maxBytes) {
            $batchNumber++
            $id = 'Batch_{0:D3}' -f $batchNumber
            $listPath = Join-Path $lists "$id.txt"
            $dest = Join-Path $output "$id.mp4"
            $lines = @($current | ForEach-Object { "file '" + $_.Path.Replace('\','/').Replace("'", "'\''") + "'" })
            [IO.File]::WriteAllLines($listPath,[string[]]$lines,[Text.UTF8Encoding]::new($false))
            $order=0
            foreach ($clip in $current) {
                $order++
                $manifest += [pscustomobject]@{Batch=$id;Order=$order;Source=$clip.Path;SizeBytes=$clip.Bytes;Target=$dest;List=$listPath;Signature=$clip.Signature;Status='Planned - not merged'}
            }
            $current=@(); $sum=[long]0
        }
        $current += $item
        $sum += $item.Bytes
    }
    if ($current.Count -gt 0) {
        $batchNumber++
        $id = 'Batch_{0:D3}' -f $batchNumber
        $listPath = Join-Path $lists "$id.txt"
        $dest = Join-Path $output "$id.mp4"
        $lines = @($current | ForEach-Object { "file '" + $_.Path.Replace('\','/').Replace("'", "'\''") + "'" })
        [IO.File]::WriteAllLines($listPath,[string[]]$lines,[Text.UTF8Encoding]::new($false))
        $order=0
        foreach ($clip in $current) {
            $order++
            $manifest += [pscustomobject]@{Batch=$id;Order=$order;Source=$clip.Path;SizeBytes=$clip.Bytes;Target=$dest;List=$listPath;Signature=$clip.Signature;Status='Planned - not merged'}
        }
    }
}
$manifestPath = Join-Path $work 'video_batch_manifest.csv'
$manifest | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
$skipped | Export-Csv -LiteralPath (Join-Path $work 'video_batch_skipped.csv') -NoTypeInformation -Encoding UTF8
Write-Host "Created $batchNumber batch lists for $($manifest.Count) videos."
Write-Host "Manifest: $manifestPath"
Write-Host "Skipped: $($skipped.Count)"
Write-Host 'No videos have been merged, moved, or deleted.'
Write-Host 'To test the first batch, run:'
Write-Host ('ffmpeg -n -f concat -safe 0 -i "{0}" -c copy "{1}"' -f (Join-Path $lists 'Batch_001.txt'),(Join-Path $output 'Batch_001.mp4'))
