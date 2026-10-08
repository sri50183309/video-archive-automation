# Phase 1: read-only recursive inventory for video archive automation.
# Windows PowerShell 5.1+; ffprobe must be available on PATH.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,
    [string]$ReportRoot = (Join-Path $PSScriptRoot 'InventoryReports'),
    [switch]$IncludeGeneratedFolders
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { throw 'ffprobe was not found on PATH.' }
$source = (Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).ProviderPath.TrimEnd('\','/')
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Not a folder: $source" }
$reportFull = [IO.Path]::GetFullPath($ReportRoot).TrimEnd('\','/')
if ($reportFull -eq $source) { throw 'ReportRoot must not be SourceRoot.' }
# Avoid writing reports inside the media collection; the repository folder is recommended.
if ($reportFull.StartsWith($source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Warning 'ReportRoot is within SourceRoot. That directory will be excluded from scanning.'
}
New-Item -ItemType Directory -Path $reportFull -Force | Out-Null
$extensions = @('.mp4','.mov','.avi','.3gp','.m4v','.mkv','.mts','.m2ts','.mpg','.mpeg','.wmv','.webm')
$excludedNames = @('VideoLists','BatchLists','MergedBatches','NormalizedBatches','NormalizedWork','NormalizedLogs','Logs','ToBeDeleted')
$records = New-Object 'System.Collections.Generic.List[object]'
$errors = New-Object 'System.Collections.Generic.List[object]'
$scanTime = (Get-Date).ToString('s')
# Enumerate with explicit recursion to skip output folders, junctions and reparse points.
$pending = New-Object 'System.Collections.Generic.Stack[string]'
$pending.Push($source)
$folderErrors = 0
while ($pending.Count -gt 0) {
    $dir = $pending.Pop()
    try { $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) }
    catch {
        $folderErrors++
        $errors.Add([pscustomobject]@{Path=$dir;Error=$_.Exception.Message})
        continue
    }
    foreach ($item in $children) {
        if ($item.PSIsContainer) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $childPath = $item.FullName.TrimEnd('\','/')
            if ($childPath -eq $reportFull) { continue }
            if (-not $IncludeGeneratedFolders -and $item.Name -in $excludedNames) { continue }
            $pending.Push($childPath)
            continue
        }
        if ($extensions -notcontains $item.Extension.ToLowerInvariant()) { continue }
        $relative = $item.FullName.Substring($source.Length).TrimStart('\','/')
        $relativeFolder = Split-Path -Parent $relative
        if ([string]::IsNullOrWhiteSpace($relativeFolder)) { $relativeFolder = '.' }
        $duration = $null; $vcodec = ''; $acodec = ''; $width = $null; $height = $null
        $rotation = 0; $orientation = 'Unknown'; $status = 'OK'; $issue = ''
        try {
            $raw = & ffprobe -v error -show_entries 'format=duration:stream=index,codec_type,codec_name,width,height:stream_tags=rotate:stream_side_data=rotation' -of json -- $item.FullName 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'ffprobe returned an error or no metadata' }
            $probe = ($raw -join "`n") | ConvertFrom-Json
            $video = @($probe.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1)
            $audio = @($probe.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1)
            if ($video.Count -eq 0) { throw 'No video stream found' }
            $vcodec = [string]$video[0].codec_name
            $width = [int]$video[0].width; $height = [int]$video[0].height
            if ($audio.Count -gt 0) { $acodec = [string]$audio[0].codec_name }
            $rotationValue = $null
            if ($video[0].tags -and $null -ne $video[0].tags.rotate) { $rotationValue = $video[0].tags.rotate }
            foreach ($side in @($video[0].side_data_list)) { if ($null -ne $side.rotation) { $rotationValue = $side.rotation } }
            if ($null -ne $rotationValue) { $rotation = [double]$rotationValue }
            $rot = [math]::Abs($rotation) % 180
            $displayWidth = $width; $displayHeight = $height
            if ($rot -gt 45 -and $rot -lt 135) { $displayWidth = $height; $displayHeight = $width }
            if ($displayWidth -gt $displayHeight) { $orientation = 'Landscape' }
            elseif ($displayWidth -lt $displayHeight) { $orientation = 'Portrait' }
            else { $orientation = 'Square' }
            $parsedDuration = 0.0
            if ([double]::TryParse([string]$probe.format.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedDuration)) { $duration = [math]::Round($parsedDuration,2) }
        } catch {
            $status = 'ProbeFailed'; $issue = $_.Exception.Message
            $errors.Add([pscustomobject]@{Path=$item.FullName;Error=$issue})
        }
        $records.Add([pscustomobject]@{
            ScannedAt=$scanTime;SourceRoot=$source;RelativeFolder=$relativeFolder;RelativePath=$relative
            FileName=$item.Name;FullPath=$item.FullName;Extension=$item.Extension.ToLowerInvariant()
            SizeBytes=$item.Length;SizeGiB=[math]::Round($item.Length / 1GB,4)
            DurationSeconds=$duration;VideoCodec=$vcodec;AudioCodec=$acodec
            Width=$width;Height=$height;RotationDegrees=$rotation;Orientation=$orientation
            LastWriteTime=$item.LastWriteTime.ToString('s');Status=$status;Error=$issue
        })
    }
}
$inventory = Join-Path $reportFull 'video_inventory.csv'
$summary = Join-Path $reportFull 'folder_summary.csv'
$errorFile = Join-Path $reportFull 'scan_errors.csv'
$summaryText = Join-Path $reportFull 'scan_summary.txt'
$records | Sort-Object RelativePath | Export-Csv -LiteralPath $inventory -NoTypeInformation -Encoding UTF8
$groups = @($records | Group-Object RelativeFolder | Sort-Object Name | ForEach-Object {
    $members = @($_.Group)
    [pscustomobject]@{
        RelativeFolder=$_.Name;VideoCount=$members.Count
        TotalGiB=[math]::Round((($members | Measure-Object SizeBytes -Sum).Sum / 1GB),3)
        DurationHours=[math]::Round((($members | Measure-Object DurationSeconds -Sum).Sum / 3600),2)
        PortraitCount=@($members | Where-Object Orientation -eq 'Portrait').Count
        LandscapeCount=@($members | Where-Object Orientation -eq 'Landscape').Count
        ProbeFailures=@($members | Where-Object Status -ne 'OK').Count
    }
})
$groups | Export-Csv -LiteralPath $summary -NoTypeInformation -Encoding UTF8
$errors | Export-Csv -LiteralPath $errorFile -NoTypeInformation -Encoding UTF8
$bytes = ($records | Measure-Object SizeBytes -Sum).Sum
@(
    'Video archive dry-run inventory'
    "Source: $source"
    "Scanned at: $scanTime"
    "Videos: $($records.Count)"
    "Folders containing videos: $($groups.Count)"
    ('Total size: {0:N2} GiB' -f ($bytes / 1GB))
    "Probe failures: $(@($records | Where-Object Status -ne 'OK').Count)"
    "Folder scan failures: $folderErrors"
    'No source videos were modified.'
) | Set-Content -LiteralPath $summaryText -Encoding UTF8
Write-Host "Inventory complete: $($records.Count) videos in $($groups.Count) folders." -ForegroundColor Green
Write-Host "Reports: $reportFull"
Write-Host 'No source videos were modified.'
