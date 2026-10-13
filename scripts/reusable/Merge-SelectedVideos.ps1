# Standalone normalize + merge for hand-picked videos (Windows PowerShell 5.1+).
# Source videos are never modified; output must be outside the input folder.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SourceFolder,
  [Parameter(Mandatory=$true)][string]$OutputFile,
  [ValidateRange(0,51)][int]$Crf=20,
  [ValidateSet('ultrafast','superfast','veryfast','faster','fast','medium','slow')][string]$Preset='fast'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
foreach($tool in @('ffmpeg','ffprobe')) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found in PATH" }
}
$root=(Resolve-Path -LiteralPath $SourceFolder -ErrorAction Stop).ProviderPath.TrimEnd('\')
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'SourceFolder must be a directory' }
$out=[IO.Path]::GetFullPath($OutputFile)
if (-not $out.EndsWith('.mp4',[StringComparison]::OrdinalIgnoreCase)) { throw 'OutputFile must end with .mp4' }
if ($out.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'OutputFile must be outside SourceFolder' }
if (Test-Path -LiteralPath $out) { throw "Output already exists: $out" }
$parent=Split-Path -Parent $out
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output directory missing: $parent" }
$partial=Join-Path $parent ([IO.Path]::GetFileNameWithoutExtension($out)+'.partial.mp4')
if (Test-Path -LiteralPath $partial) { throw "Partial output exists; inspect before retry: $partial" }
$ext=@('.mp4','.mov','.m4v','.mkv','.avi','.wmv','.3gp')
$files=@(Get-ChildItem -LiteralPath $root -File | Where-Object { $ext -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name)
if ($files.Count -lt 2) { throw "At least two videos required; found $($files.Count)" }
Write-Host "Merging $($files.Count) videos in filename order:" -ForegroundColor Cyan
$files | ForEach-Object { Write-Host "  $($_.Name)" }
$durations=[Collections.Generic.List[string]]::new()
$hasAudio=[Collections.Generic.List[bool]]::new()
foreach($f in $files) {
  $raw=& ffprobe -v error -show_entries 'format=duration:stream=codec_type' -of json $f.FullName
  if ($LASTEXITCODE -ne 0) { throw "ffprobe failed: $($f.FullName)" }
  $p=($raw -join "`n") | ConvertFrom-Json
  if (-not $p.format.duration) { throw "Missing duration: $($f.FullName)" }
  if (@($p.streams | Where-Object { $_.codec_type -eq 'video' }).Count -eq 0) { throw "Missing video: $($f.FullName)" }
  $durations.Add([string]$p.format.duration)
  $hasAudio.Add((@($p.streams | Where-Object { $_.codec_type -eq 'audio' }).Count -gt 0))
}
$argsList=[Collections.Generic.List[string]]::new()
foreach($f in $files) { $argsList.Add('-i'); $argsList.Add($f.FullName) }
$silent=@{}
$next=$files.Count
for($i=0;$i -lt $files.Count;$i++) {
  if (-not $hasAudio[$i]) {
    foreach($arg in @('-f','lavfi','-t',$durations[$i],'-i','anullsrc=r=48000:cl=stereo')) { $argsList.Add($arg) }
    $silent[$i]=$next; $next++
  }
}
$filters=[Collections.Generic.List[string]]::new()
$concat=''
for($i=0;$i -lt $files.Count;$i++) {
  $filters.Add("[${i}:v:0]fps=30,scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,setsar=1,format=yuv420p,setpts=PTS-STARTPTS[v$i]")
  $a=$i
  if ($silent.ContainsKey($i)) { $a=$silent[$i] }
  $filters.Add("[${a}:a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,asetpts=PTS-STARTPTS[a$i]")
  $concat += "[v$i][a$i]"
}
$filters.Add("${concat}concat=n=$($files.Count):v=1:a=1[v][a]")
foreach($arg in @('-filter_complex',($filters -join ';'),'-map','[v]','-map','[a]','-c:v','libx264','-preset',$Preset,'-crf',[string]$Crf,'-c:a','aac','-b:a','256k','-ar','48000','-ac','2','-movflags','+faststart','-n',$partial)) { $argsList.Add($arg) }
Write-Host 'Encoding and merging; originals remain unchanged...' -ForegroundColor Cyan
& ffmpeg -hide_banner -nostdin @($argsList.ToArray())
if ($LASTEXITCODE -ne 0) { throw "Encoding failed ($LASTEXITCODE); partial retained: $partial" }
Write-Host 'Validating full output decode...' -ForegroundColor Cyan
& ffmpeg -hide_banner -nostdin -v error -xerror -i $partial -map '0:v:0' -map '0:a:0' -f null NUL
if ($LASTEXITCODE -ne 0) { throw "Validation failed; partial retained: $partial" }
Move-Item -LiteralPath $partial -Destination $out -ErrorAction Stop
Write-Host "SUCCESS: $out" -ForegroundColor Green
Write-Host 'Original videos unchanged. Manually check playback.'
