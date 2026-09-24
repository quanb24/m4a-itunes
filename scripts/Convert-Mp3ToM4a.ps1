<#
.SYNOPSIS
    Batch-converts MP3 files to M4A (AAC-LC or ALAC) for Apple Music / iTunes / iPhone,
    mirroring the source folder structure and keeping tags and embedded album artwork.

.DESCRIPTION
    - Recursively finds every .mp3 under -Source.
    - Writes each file to the same relative path under -Destination with a .m4a extension.
    - Never touches or deletes the original MP3 files.
    - Skips outputs that already exist (so re-running never creates duplicates),
      unless -Overwrite is given.
    - Copies all tags (title, artist, album, album artist, track, disc, genre, year,
      composer, compilation flag, comment) with -map_metadata 0.
    - Copies JPEG/PNG artwork untouched. Artwork in any other format (BMP, GIF, ...) is
      converted to JPEG, because FFmpeg would otherwise store it mislabelled and it would
      show up blank in Apple Music.
    - Writes to a temporary .part file first, so an interrupted run never leaves a
      half-written .m4a behind.
    - Failures are listed at the end and written to conversion-errors.log in -Destination.

.PARAMETER Source
    Folder that contains your MP3 files (subfolders are included).

.PARAMETER Destination
    Folder where the M4A files will be written. Created if it does not exist.
    Use a folder OUTSIDE -Source.

.PARAMETER Codec
    'aac' (default, recommended) or 'alac'.

.PARAMETER Bitrate
    AAC bitrate. Default '256k'. Ignored for ALAC.

.PARAMETER Overwrite
    Re-convert files even if the .m4a already exists.

.EXAMPLE
    .\Convert-Mp3ToM4a.ps1 -Source "D:\Music\MP3" -Destination "D:\Music\M4A"

.EXAMPLE
    .\Convert-Mp3ToM4a.ps1 -Source "D:\Music\MP3" -Destination "D:\Music\ALAC" -Codec alac
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [ValidateSet('aac', 'alac')][string]$Codec = 'aac',
    [string]$Bitrate = '256k',
    [switch]$Overwrite
)

foreach ($tool in 'ffmpeg', 'ffprobe') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool was not found on PATH. Install FFmpeg (see README) and open a NEW PowerShell window."
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    Write-Error "Source folder not found: $Source"
    exit 1
}

$srcRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Source).ProviderPath).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}
$dstRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Destination).ProviderPath).TrimEnd('\', '/')

if ($srcRoot -eq $dstRoot) {
    Write-Error "Source and Destination must be different folders."
    exit 1
}

if ($Codec -eq 'aac') {
    $audioArgs = @('-c:a', 'aac', '-profile:a', 'aac_low', '-b:a', $Bitrate)
} else {
    $audioArgs = @('-c:a', 'alac', '-sample_fmt', 's16p')
}

$files = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File |
    Where-Object { $_.Extension -eq '.mp3' } |
    Sort-Object FullName)

if ($files.Count -eq 0) {
    Write-Host "No .mp3 files found under $srcRoot"
    exit 0
}

Write-Host "Found $($files.Count) MP3 file(s). Codec: $Codec$(if ($Codec -eq 'aac') { " @ $Bitrate" })"
Write-Host "Source:      $srcRoot"
Write-Host "Destination: $dstRoot"
Write-Host ''

$converted = 0
$skipped = 0
$failed = New-Object System.Collections.Generic.List[string]
$i = 0

foreach ($file in $files) {
    $i++
    $rel = $file.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
    $outFile = Join-Path $dstRoot ([System.IO.Path]::ChangeExtension($rel, '.m4a'))
    $outDir = Split-Path -Parent $outFile
    $partFile = "$outFile.part"

    if ((Test-Path -LiteralPath $outFile) -and -not $Overwrite) {
        $skipped++
        Write-Host "[$i/$($files.Count)] skip (exists)  $rel"
        continue
    }

    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    # What kind of embedded artwork (if any) does this MP3 have?
    $coverCodec = (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name `
            -of default=noprint_wrappers=1:nokey=1 $file.FullName 2>$null | Select-Object -First 1)
    if ($coverCodec) { $coverCodec = "$coverCodec".Trim() }

    if (-not $coverCodec) {
        $coverArgs = @()
    } elseif ($coverCodec -eq 'mjpeg' -or $coverCodec -eq 'png') {
        $coverArgs = @('-map', '0:v:0', '-c:v', 'copy', '-disposition:v:0', 'attached_pic')
    } else {
        # BMP/GIF/etc.: re-encode to a high-quality JPEG so Apple Music can display it.
        $coverArgs = @('-map', '0:v:0', '-c:v', 'mjpeg', '-q:v', '2', '-disposition:v:0', 'attached_pic')
    }

    $ffArgs = @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
        '-i', $file.FullName,
        '-map', '0:a:0') + $coverArgs + @(
        '-map_metadata', '0') + $audioArgs + @(
        '-movflags', '+faststart',
        '-f', 'ipod',
        $partFile)

    Write-Host "[$i/$($files.Count)] convert        $rel"
    $ffOutput = & ffmpeg @ffArgs 2>&1 | ForEach-Object { "$_" }

    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $partFile)) {
        Move-Item -LiteralPath $partFile -Destination $outFile -Force
        $converted++
    } else {
        if (Test-Path -LiteralPath $partFile) { Remove-Item -LiteralPath $partFile -Force }
        $msg = "$rel :: " + (($ffOutput | Where-Object { $_ }) -join ' | ')
        $failed.Add($msg)
        Write-Warning "FAILED: $msg"
    }
}

Write-Host ''
Write-Host "Done. Converted: $converted   Skipped (already existed): $skipped   Failed: $($failed.Count)"

if ($failed.Count -gt 0) {
    $log = Join-Path $dstRoot 'conversion-errors.log'
    $failed | Set-Content -LiteralPath $log -Encoding UTF8
    Write-Host "Failures written to: $log"
    exit 2
}
