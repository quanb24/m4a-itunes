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
    - Checks every MP3 with ffprobe first; empty, damaged or non-audio files are reported
      as failures instead of being passed to FFmpeg.
    - Writes to a temporary .part file first. The .part file is only renamed to .m4a after
      ffprobe confirms it is readable and contains the expected AAC or ALAC audio stream,
      so an interrupted or failed conversion never leaves a half-written .m4a behind.
    - Refuses to run if -Destination is the same folder as -Source, is inside it, or
      contains it.
    - Failures are listed at the end and written to conversion-errors.log in -Destination.

.PARAMETER Source
    Folder that contains your MP3 files (subfolders are included).

.PARAMETER Destination
    Folder where the M4A files will be written. Created if it does not exist.
    Must be OUTSIDE -Source (not the same folder, not a subfolder of it, not a parent of it).

.PARAMETER Codec
    'aac' (default, recommended) or 'alac'.

.PARAMETER Bitrate
    AAC bitrate, 64k to 320k, written as '256k' or '256000'. Default '256k'. Ignored for ALAC.

.PARAMETER Overwrite
    Re-convert files even if the .m4a already exists.

.EXAMPLE
    .\Convert-Mp3ToM4a.ps1 -Source "D:\Music\MP3" -Destination "D:\Music\M4A"

.EXAMPLE
    .\Convert-Mp3ToM4a.ps1 -Source "D:\Music\MP3" -Destination "D:\Music\ALAC" -Codec alac
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Source,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Destination,
    [ValidateSet('aac', 'alac')][string]$Codec = 'aac',
    [string]$Bitrate = '256k',
    [switch]$Overwrite
)

function Stop-WithError([string]$Message) {
    Write-Error $Message
    exit 1
}

# Absolute, normalized folder path. Works for folders that do not exist yet and resolves
# relative paths against the current PowerShell location. Only a drive root keeps its
# trailing separator.
function Get-NormalizedPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    if ($full.Length -gt [System.IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd('\', '/') }
    $full
}

# True if $Child is $Parent or anywhere below it. Case-insensitive, to be safe on Windows/macOS.
function Test-IsSameOrInside([string]$Child, [string]$Parent) {
    $sep = [System.IO.Path]::DirectorySeparatorChar
    ($Child.TrimEnd('\', '/') + $sep).StartsWith($Parent.TrimEnd('\', '/') + $sep, [System.StringComparison]::OrdinalIgnoreCase)
}

# Runs a native tool and returns its exit code, stdout and stderr separately.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $stdout = New-Object System.Collections.Generic.List[string]
    $stderr = New-Object System.Collections.Generic.List[string]
    & $Exe @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $stderr.Add("$_".Trim()) } else { $stdout.Add("$_") }
    }
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        StdOut   = $stdout -join "`n"
        StdErr   = ($stderr | Where-Object { $_ }) -join ' | '
    }
}

# Streams of a media file via ffprobe. Returns an object with Error set if it can't be read.
function Get-Streams([string]$Path, [switch]$CountPackets) {
    $probeArgs = @('-v', 'error')
    if ($CountPackets) { $probeArgs += '-count_packets' }
    $probeArgs += @('-show_entries', 'stream=codec_type,codec_name,nb_read_packets', '-of', 'json', $Path)
    $r = Invoke-Native 'ffprobe' $probeArgs
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ Error = "ffprobe could not read it (exit $($r.ExitCode)): $($r.StdErr)"; Streams = @(); StdErr = $r.StdErr }
    }
    try {
        $data = $r.StdOut | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Error = "ffprobe returned unreadable output: $($_.Exception.Message)"; Streams = @(); StdErr = $r.StdErr }
    }
    [pscustomobject]@{ Error = $null; Streams = @($data.streams | Where-Object { $_ }); StdErr = $r.StdErr }
}

# Returns $null if the finished .part file is a readable M4A with the expected audio stream,
# otherwise a description of the problem.
function Test-ConvertedFile([string]$Path, [string]$ExpectedCodec) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'FFmpeg reported success but wrote no output file' }
    if ((Get-Item -LiteralPath $Path).Length -eq 0) { return 'output file is empty' }
    $probe = Get-Streams $Path -CountPackets
    if ($probe.Error) { return "output check failed: $($probe.Error)" }
    if ($probe.StdErr) { return "output check failed: ffprobe reported errors: $($probe.StdErr)" }
    $audio = @($probe.Streams | Where-Object { $_.codec_type -eq 'audio' })
    if ($audio.Count -ne 1) { return "output check failed: expected 1 audio stream, found $($audio.Count)" }
    if ($audio[0].codec_name -ne $ExpectedCodec) { return "output check failed: audio codec is '$($audio[0].codec_name)', expected '$ExpectedCodec'" }
    $packets = 0
    if (-not [int]::TryParse("$($audio[0].nb_read_packets)", [ref]$packets) -or $packets -le 0) {
        return 'output check failed: audio stream contains no audio data'
    }
    $null
}

# --- Check FFmpeg -------------------------------------------------------------

foreach ($tool in 'ffmpeg', 'ffprobe') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Stop-WithError "$tool was not found on PATH. Install FFmpeg (see README) and open a NEW PowerShell window."
    }
}
$encoders = Invoke-Native 'ffmpeg' @('-hide_banner', '-encoders')
if ($encoders.ExitCode -ne 0) {
    Stop-WithError "ffmpeg does not run correctly (exit $($encoders.ExitCode)): $($encoders.StdErr)"
}
if ($encoders.StdOut -notmatch "(?m)^\s*A\S*\s+$Codec\s") {
    Stop-WithError "This FFmpeg build has no '$Codec' encoder. Install a standard build (see README)."
}

# --- Check parameters and folders ---------------------------------------------

if ($Codec -eq 'aac') {
    if ($Bitrate -notmatch '^\s*(\d{1,7})\s*([kK]?)\s*$') {
        Stop-WithError "Invalid -Bitrate '$Bitrate'. Use a value like 256k or 256000."
    }
    $kbps = if ($Matches[2]) { [int]$Matches[1] } else { [int]$Matches[1] / 1000 }
    if ($kbps -lt 64 -or $kbps -gt 320 -or $kbps -ne [math]::Floor($kbps)) {
        Stop-WithError "Invalid -Bitrate '$Bitrate'. Use a whole number of kbps between 64k and 320k (recommended: 256k)."
    }
    $Bitrate = "$($kbps)k"
} elseif ($PSBoundParameters.ContainsKey('Bitrate')) {
    Write-Warning '-Bitrate is ignored with -Codec alac (lossless has no bitrate setting).'
}

if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Destination)) {
    Stop-WithError 'Source and Destination must not be blank.'
}
try {
    $srcRoot = Get-NormalizedPath $Source
    $dstRoot = Get-NormalizedPath $Destination
} catch {
    Stop-WithError "Invalid folder path: $($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $srcRoot -PathType Container)) {
    Stop-WithError "Source folder not found (or is not a folder): $srcRoot"
}
if ((Test-Path -LiteralPath $dstRoot) -and -not (Test-Path -LiteralPath $dstRoot -PathType Container)) {
    Stop-WithError "Destination exists but is a file, not a folder: $dstRoot"
}
if (Test-IsSameOrInside $dstRoot $srcRoot) {
    Stop-WithError "Destination must not be the Source folder or inside it. Source: $srcRoot  Destination: $dstRoot"
}
if (Test-IsSameOrInside $srcRoot $dstRoot) {
    Stop-WithError "Source must not be inside the Destination folder. Source: $srcRoot  Destination: $dstRoot"
}

if ($Codec -eq 'aac') {
    $audioArgs = @('-c:a', 'aac', '-profile:a', 'aac_low', '-b:a', $Bitrate)
} else {
    $audioArgs = @('-c:a', 'alac', '-sample_fmt', 's16p')
}

# --- Find MP3 files -----------------------------------------------------------

$files = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable listErrors |
    Where-Object { $_.Extension -eq '.mp3' } |
    Sort-Object FullName)
foreach ($e in $listErrors) { Write-Warning "Could not read part of the Source folder: $($e.Exception.Message)" }

if ($files.Count -eq 0) {
    Write-Host "No .mp3 files found under $srcRoot"
    exit 0
}

try {
    [System.IO.Directory]::CreateDirectory($dstRoot) | Out-Null
} catch {
    Stop-WithError "Could not create Destination folder '$dstRoot': $($_.Exception.Message)"
}

Write-Host "Found $($files.Count) MP3 file(s). Codec: $Codec$(if ($Codec -eq 'aac') { " @ $Bitrate" })"
Write-Host "Source:      $srcRoot"
Write-Host "Destination: $dstRoot"
Write-Host ''

# --- Convert ------------------------------------------------------------------

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

    # A folder with the output's name would make the final rename move the file into it.
    if (Test-Path -LiteralPath $outFile -PathType Container) {
        $msg = "$rel :: a folder named like the output already exists: $outFile"
        $failed.Add($msg)
        Write-Warning "FAILED: $msg"
        continue
    }

    if ((Test-Path -LiteralPath $outFile -PathType Leaf) -and -not $Overwrite) {
        $skipped++
        Write-Host "[$i/$($files.Count)] skip (exists)  $rel"
        continue
    }

    Write-Host "[$i/$($files.Count)] convert        $rel"
    $problem = $null

    try {
        # Check the MP3 is readable and has audio before handing it to FFmpeg.
        if ($file.Length -eq 0) {
            $problem = 'MP3 is empty (0 bytes)'
        } else {
            $probe = Get-Streams $file.FullName
            if ($probe.Error) {
                $problem = "MP3 is damaged or not an audio file: $($probe.Error)"
            } elseif (-not @($probe.Streams | Where-Object { $_.codec_type -eq 'audio' }).Count) {
                $problem = 'MP3 contains no audio stream'
            }
        }

        if (-not $problem) {
            # What kind of embedded artwork (if any) does this MP3 have?
            $cover = @($probe.Streams | Where-Object { $_.codec_type -eq 'video' }) | Select-Object -First 1
            $coverCodec = if ($cover) { "$($cover.codec_name)".Trim() } else { $null }

            if (-not $coverCodec) {
                $coverArgs = @()
            } elseif ($coverCodec -eq 'mjpeg' -or $coverCodec -eq 'png') {
                $coverArgs = @('-map', '0:v:0', '-c:v', 'copy', '-disposition:v:0', 'attached_pic')
            } else {
                # BMP/GIF/etc.: re-encode to a high-quality JPEG so Apple Music can display it.
                $coverArgs = @('-map', '0:v:0', '-c:v', 'mjpeg', '-q:v', '2', '-disposition:v:0', 'attached_pic')
            }

            if (-not (Test-Path -LiteralPath $outDir -PathType Container)) {
                [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
            }

            $ffArgs = @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
                '-i', $file.FullName,
                '-map', '0:a:0') + $coverArgs + @(
                '-map_metadata', '0') + $audioArgs + @(
                '-movflags', '+faststart',
                '-f', 'ipod',
                $partFile)

            $ff = Invoke-Native 'ffmpeg' $ffArgs
            if ($ff.ExitCode -ne 0) {
                $problem = "ffmpeg failed (exit $($ff.ExitCode)): $($ff.StdErr)"
            } else {
                $problem = Test-ConvertedFile $partFile $Codec
                if (-not $problem) {
                    Move-Item -LiteralPath $partFile -Destination $outFile -Force -ErrorAction Stop
                    $converted++
                    if ($ff.StdErr) { Write-Warning "Converted, but FFmpeg reported problems in the MP3 (check how it sounds): $rel :: $($ff.StdErr)" }
                }
            }
        }
    } catch {
        $problem = "$($_.Exception.Message)"
    } finally {
        # Also runs on Ctrl+C: never leave a .part file behind.
        if (Test-Path -LiteralPath $partFile) { Remove-Item -LiteralPath $partFile -Force -ErrorAction SilentlyContinue }
    }

    if ($problem) {
        $msg = "$rel :: $problem"
        $failed.Add($msg)
        Write-Warning "FAILED: $msg"
    }
}

Write-Host ''
Write-Host "Done. Converted: $converted   Skipped (already existed): $skipped   Failed: $($failed.Count)"

if ($failed.Count -gt 0) {
    $log = Join-Path $dstRoot 'conversion-errors.log'
    try {
        $failed | Set-Content -LiteralPath $log -Encoding UTF8 -ErrorAction Stop
        Write-Host "Failures written to: $log"
    } catch {
        Write-Warning "Could not write $log : $($_.Exception.Message)"
    }
    exit 2
}
