<#
.SYNOPSIS
    Checks a converted M4A library against the original MP3 folder.

.DESCRIPTION
    For every MP3 under -Source it checks the matching .m4a under -Destination:
      - the .m4a exists
      - the audio codec is AAC or ALAC and the duration matches the MP3 (within 1 second)
      - title, artist, album, album_artist, track, disc, genre and date match the MP3
      - if the MP3 had embedded artwork, the .m4a has it too
    It also reports:
      - .m4a files with no matching MP3 (strays / accidental extra copies)
      - leftover .part files from an interrupted run
      - songs that appear more than once in -Destination (same artist + album + disc + track + title)

    Results are printed and saved to verify-report.csv in -Destination.
    Nothing is modified.

.EXAMPLE
    .\Verify-M4aLibrary.ps1 -Source "D:\Music\MP3" -Destination "D:\Music\M4A"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
)

if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Error 'ffprobe was not found on PATH. It ships with FFmpeg; see README.'
    exit 1
}

$srcRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Source).ProviderPath).TrimEnd('\', '/')
$dstRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Destination).ProviderPath).TrimEnd('\', '/')

$tagKeys = 'title', 'artist', 'album', 'album_artist', 'track', 'disc', 'genre', 'date'

function Get-MediaInfo([string]$path) {
    $json = & ffprobe -v error -print_format json -show_format -show_streams $path 2>$null | Out-String
    if (-not $json.Trim()) { return $null }
    $data = $json | ConvertFrom-Json

    $tags = @{}
    if ($data.format.tags) {
        foreach ($p in $data.format.tags.PSObject.Properties) { $tags[$p.Name.ToLowerInvariant()] = "$($p.Value)".Trim() }
    }
    $audio = @($data.streams | Where-Object { $_.codec_type -eq 'audio' }) | Select-Object -First 1
    $art = @($data.streams | Where-Object { $_.codec_type -eq 'video' -and $_.disposition.attached_pic -eq 1 })

    [pscustomobject]@{
        Tags       = $tags
        AudioCodec = if ($audio) { $audio.codec_name } else { $null }
        Duration   = [double]$data.format.duration
        HasArt     = $art.Count -gt 0
    }
}

$dupIndex = @{}
function Add-DupEntry($info, [string]$path) {
    if (-not $info -or -not $info.Tags['title']) { return }
    $key = ('artist', 'album', 'disc', 'track', 'title' |
            ForEach-Object { "$($info.Tags[$_])".ToLowerInvariant() }) -join '|'
    if (-not $dupIndex.ContainsKey($key)) { $dupIndex[$key] = New-Object System.Collections.Generic.List[string] }
    $dupIndex[$key].Add($path)
}

function Get-RelativeKey([string]$root, [string]$full) {
    [System.IO.Path]::ChangeExtension($full.Substring($root.Length).TrimStart('\', '/'), $null).TrimEnd('.').ToLowerInvariant()
}

$mp3s = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File | Where-Object { $_.Extension -eq '.mp3' })
$m4as = @(Get-ChildItem -LiteralPath $dstRoot -Recurse -File | Where-Object { $_.Extension -eq '.m4a' })
$parts = @(Get-ChildItem -LiteralPath $dstRoot -Recurse -File | Where-Object { $_.Name -like '*.m4a.part' })

$m4aByKey = @{}
foreach ($f in $m4as) { $m4aByKey[(Get-RelativeKey $dstRoot $f.FullName)] = $f }
$mp3Keys = @{}

$report = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($mp3 in $mp3s) {
    $i++
    Write-Progress -Activity 'Verifying' -Status $mp3.Name -PercentComplete (100 * $i / $mp3s.Count)
    $key = Get-RelativeKey $srcRoot $mp3.FullName
    $mp3Keys[$key] = $true
    $problems = New-Object System.Collections.Generic.List[string]

    $m4a = $m4aByKey[$key]
    if (-not $m4a) {
        $problems.Add('M4A missing')
    } else {
        $src = Get-MediaInfo $mp3.FullName
        $dst = Get-MediaInfo $m4a.FullName
        if (-not $dst) {
            $problems.Add('M4A unreadable')
        } else {
            if ($dst.AudioCodec -notin 'aac', 'alac') { $problems.Add("audio codec is '$($dst.AudioCodec)'") }
            if ($src -and [math]::Abs($src.Duration - $dst.Duration) -gt 1.0) {
                $problems.Add(('duration {0:N1}s vs MP3 {1:N1}s' -f $dst.Duration, $src.Duration))
            }
            if ($src) {
                foreach ($k in $tagKeys) {
                    $a = $src.Tags[$k]; $b = $dst.Tags[$k]
                    if ($a -and $a -ne $b) { $problems.Add("$k differs ('$a' -> '$b')") }
                }
                if ($src.HasArt -and -not $dst.HasArt) { $problems.Add('artwork missing') }
            }
            Add-DupEntry $dst $m4a.FullName
        }
    }

    $report.Add([pscustomobject]@{
            File   = $mp3.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
            Status = if ($problems.Count) { 'PROBLEM' } else { 'OK' }
            Detail = $problems -join '; '
        })
}
Write-Progress -Activity 'Verifying' -Completed

foreach ($k in $m4aByKey.Keys) {
    if (-not $mp3Keys.ContainsKey($k)) {
        $report.Add([pscustomobject]@{ File = $m4aByKey[$k].FullName; Status = 'EXTRA'; Detail = 'M4A has no matching MP3 in Source' })
        Add-DupEntry (Get-MediaInfo $m4aByKey[$k].FullName) $m4aByKey[$k].FullName
    }
}
foreach ($p in $parts) {
    $report.Add([pscustomobject]@{ File = $p.FullName; Status = 'PARTIAL'; Detail = 'Leftover .part file from an interrupted run - delete it and re-run the converter' })
}
foreach ($entry in $dupIndex.GetEnumerator()) {
    if ($entry.Value.Count -gt 1) {
        $report.Add([pscustomobject]@{ File = ($entry.Value -join ' <> '); Status = 'DUPLICATE'; Detail = 'Same artist/album/disc/track/title in more than one M4A' })
    }
}

$csv = Join-Path $dstRoot 'verify-report.csv'
$report | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

$ok = @($report | Where-Object Status -eq 'OK').Count
$bad = @($report | Where-Object Status -ne 'OK')
Write-Host ''
Write-Host "MP3 files: $($mp3s.Count)   M4A files: $($m4as.Count)   OK: $ok   Issues: $($bad.Count)"
if ($bad.Count) {
    $bad | Format-Table -AutoSize -Wrap | Out-String -Width 4096 | Write-Host
    Write-Host "Full report: $csv"
    exit 2
}
Write-Host "Everything matches. Report: $csv"
