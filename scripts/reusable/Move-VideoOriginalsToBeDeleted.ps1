# One-time relocation for BalVihar and ShravanSportsVideos after manual review.
# Windows PowerShell 5.1. No permanent deletion. Run -Mode Preview before -Mode Move.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('Preview','Move')][string]$Mode,
  [string]$Base='E:\LenovoLaptop\Personnel\Videos\IpadUpload - Copy'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$specs=@(
  [pscustomobject]@{Name='BalVihar';Unique=44;Duplicates=11;Groups=7},
  [pscustomobject]@{Name='ShravanSportsVideos';Unique=31;Duplicates=4;Groups=4}
)
$all=[Collections.Generic.List[object]]::new()
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($spec in $specs) {
  $root=Join-Path $Base $spec.Name
  $work=Join-Path $root 'Archive_Work'
  $manifestFile=Join-Path $work 'Manifest.csv'
  $duplicatesFile=Join-Path $work 'Duplicates.csv'
  $planFile=Join-Path $work 'GroupPlan.csv'
  $settingsFile=Join-Path $work 'Settings.json'
  foreach($f in @($manifestFile,$duplicatesFile,$planFile,$settingsFile)) {
    if(-not (Test-Path -LiteralPath $f -PathType Leaf)){throw "Required file missing: $f"}
  }
  $settings=Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
  if([int]$settings.Version -ne 2){throw "Unexpected plan version: $root"}
  if((Get-FileHash -LiteralPath $manifestFile -Algorithm SHA256).Hash -ne $settings.ManifestHash){throw "Manifest modified: $root"}
  if((Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash -ne $settings.PlanHash){throw "Group plan modified: $root"}
  $unique=@(Import-Csv -LiteralPath $manifestFile)
  $dups=@(Import-Csv -LiteralPath $duplicatesFile | Where-Object {$_ -and $_.DuplicatePath})
  $groups=@(Import-Csv -LiteralPath $planFile)
  if($unique.Count -ne $spec.Unique -or $dups.Count -ne $spec.Duplicates -or $groups.Count -ne $spec.Groups){throw "Unexpected counts: $root"}
  if([int]$settings.UniqueCount -ne $unique.Count -or [int]$settings.GroupCount -ne $groups.Count){throw "Settings counts mismatch: $root"}
  foreach($g in $groups){
    $out=Join-Path (Join-Path $work 'GroupedVideos') $g.Output
    if(-not (Test-Path -LiteralPath $out -PathType Leaf)){throw "Archive output missing: $out"}
    if((Get-Item -LiteralPath $out).Length -le 0){throw "Empty archive output: $out"}
  }
  $records=[Collections.Generic.List[object]]::new()
  foreach($r in $unique){$records.Add([pscustomobject]@{Path=$r.SourcePath;Hash=$r.SHA256})}
  foreach($r in $dups){$records.Add([pscustomobject]@{Path=$r.DuplicatePath;Hash=$r.SHA256})}
  $prefix=[IO.Path]::GetFullPath($root).TrimEnd('\')+'\'
  $holding=Join-Path $root 'ToBeDeleted'
  foreach($r in $records){
    $source=[IO.Path]::GetFullPath([string]$r.Path)
    if(-not $source.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Source outside folder: $source"}
    $relative=$source.Substring($prefix.Length)
    if($relative -match '^(?i:Archive_Work(?:_Backup_[^\\]+)?|ToBeDeleted)\\'){throw "Protected path in manifest: $source"}
    if(-not $seen.Add($source)){throw "Duplicate source path: $source"}
    if(-not (Test-Path -LiteralPath $source -PathType Leaf)){throw "Source missing: $source"}
    $item=Get-Item -LiteralPath $source
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Linked source refused: $source"}
    if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne [string]$r.Hash){throw "SHA256 mismatch: $source"}
    $destination=Join-Path $holding $relative
    if(Test-Path -LiteralPath $destination){throw "Destination already exists: $destination"}
    $all.Add([pscustomobject]@{Folder=$spec.Name;Source=$source;Destination=$destination;SHA256=[string]$r.Hash;Status='PENDING';Acceptance= $(if($spec.Name -eq 'BalVihar'){'Group 1 manually accepted; 79.82-second duration discrepancy; other groups validated'}else{'All groups automatically validated and manually reviewed'})})
  }
  # Ignore the archived plan backups, not the source recordings.
  $actual=@(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $rel=$_.FullName.Substring($prefix.Length)
    $rel -notmatch '^(?i:Archive_Work(?:_Backup_[^\\]+)?|ToBeDeleted)\\' -and
    @('.mp4','.mov','.m4v','.mkv','.avi','.wmv','.3gp') -contains $_.Extension.ToLowerInvariant()
  })
  if($actual.Count -ne $records.Count){throw "Unplanned recordings or missing inventory in ${root}: $($actual.Count) found vs $($records.Count) planned"}
  foreach($f in $actual){if(-not $seen.Contains($f.FullName)){throw "Unplanned source: $($f.FullName)"}}
  Write-Host "PREFLIGHT OK: $($spec.Name) - $($records.Count) originals, $($groups.Count) archive files" -ForegroundColor Green
}
if($all.Count -ne 90){throw "Expected 90 originals, found $($all.Count)"}
Write-Host "ALL CHECKS PASSED: 90 SHA256-verified originals. Nothing deleted." -ForegroundColor Green
if($Mode -eq 'Preview'){
  Write-Host 'PREVIEW ONLY: no files moved. To execute, run this script with -Mode Move.' -ForegroundColor Cyan
  return
}
$journal=Join-Path (Join-Path $Base 'BalVihar\Archive_Work') ('Relocation_ManualAcceptance_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'.csv')
# Write a complete journal before the first move.
$all | Export-Csv -LiteralPath $journal -NoTypeInformation -Encoding UTF8
Write-Host "Journal: $journal"
try {
  foreach($m in $all){
    $parent=Split-Path -Parent $m.Destination
    if(-not (Test-Path -LiteralPath $parent -PathType Container)) {New-Item -ItemType Directory -Path $parent -Force | Out-Null}
    Move-Item -LiteralPath $m.Source -Destination $m.Destination -ErrorAction Stop
    if((Get-FileHash -LiteralPath $m.Destination -Algorithm SHA256).Hash -ne $m.SHA256){throw "Post-move hash mismatch: $($m.Destination)"}
    $m.Status='MOVED_AND_HASH_VERIFIED'
    $all | Export-Csv -LiteralPath $journal -NoTypeInformation -Encoding UTF8
  }
} catch {
  Write-Warning 'Move interrupted. Do NOT rerun automatically. Inspect journal and ToBeDeleted first.'
  throw
}
Write-Host 'SUCCESS: 90 originals moved to per-folder ToBeDeleted and hash-verified. No files deleted.' -ForegroundColor Green
Write-Host "Journal: $journal"

