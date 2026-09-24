# MP3 → M4A for Apple Music, iTunes and iPhone (Windows, free)

A tested FFmpeg + PowerShell workflow for converting an MP3 library to M4A while keeping
tags and embedded album artwork, then syncing it to an iPhone.

> **Read this first.** Converting MP3 to *any* format can't bring back audio the MP3
> encoder already threw away. The best you can do is **add as little new loss as possible**.
> Also, Apple Music, iTunes and the iPhone all play MP3 natively, with tags and artwork.
> If all you need is for the songs to play on your iPhone, **keeping the MP3s is the
> highest-quality option: zero added loss, smallest files.** Convert only if you
> specifically want M4A files.

---

## 1. Recommendation in one sentence

**Convert with FFmpeg to AAC-LC at 256 kbps in an .m4a file, keep the source sample rate
and channels, and copy all tags and artwork — using `scripts/Convert-Mp3ToM4a.ps1`
for your whole library.**

---

## 2. Exact settings

| Setting | Value | FFmpeg option |
|---|---|---|
| Container | `.m4a` (MPEG-4 audio, iPod/iTunes flavour) | output filename `.m4a` (script uses `-f ipod`) |
| Codec | AAC-LC (`mp4a.40.2`), FFmpeg's built-in encoder | `-c:a aac -profile:a aac_low` |
| Bitrate | 256 kbps | `-b:a 256k` |
| Rate control | FFmpeg's normal bitrate-targeted mode. **Don't** use `-q:a` with FFmpeg's `aac` encoder: its VBR mode is experimental. | *(nothing else to set)* |
| Sample rate | **Same as the MP3** (nearly always 44.1 kHz). Never upsample to 48/96 kHz: it adds nothing and just resamples. | *(don't set `-ar`)* |
| Channels | **Same as the MP3** (stereo stays stereo; joint-stereo MP3 decodes to normal stereo) | *(don't set `-ac`)* |
| Tags | Copy everything | `-map_metadata 0` |
| Artwork | Copy the first embedded picture as-is (JPEG/PNG). The script converts BMP/GIF to JPEG. | `-map "0:v:0?" -c:v copy -disposition:v:0 attached_pic` |
| Streaming layout | Index at the start of the file | `-movflags +faststart` |

Tested with FFmpeg 7.0 and a 2026 build. These fields come through into the M4A:
title, artist, album, album artist, track number (e.g. 3 of 12), disc number (e.g. 2 of 2),
genre, year/date, composer, comment, compilation flag, and embedded artwork.
**Not carried over:** embedded lyrics (ID3 `USLT`). Copy lyrics with Mp3tag if you need them.

---

## 3. AAC-LC 256 VBR vs AAC-LC 320 vs ALAC: which to use

| | **AAC-LC 256 kbps** ✅ | AAC-LC 320 kbps | ALAC (Apple Lossless) |
|---|---|---|---|
| New loss added on top of the MP3 | Very small; not audible in practice at this bitrate | Slightly smaller still; not audibly different from 256 | **None**: exact copy of the decoded MP3 |
| Size of a 4-minute song | ~7.7 MB | ~9.6 MB | ~20–30 MB (roughly 3–5× the MP3) |
| iPhone / Apple Music / iTunes | Yes: this is Apple's own store format ("iTunes Plus") | Yes | Yes |
| Sounds better than the MP3? | No | No | No: identical to the MP3, never better |

- **"256 kbps VBR"** is what iTunes/Apple Music produce with Apple's encoder (iTunes Plus).
  FFmpeg's built-in AAC encoder targets 256 kbps instead of true VBR. At this bitrate both are
  far beyond the point where an MP3 source is the limiting factor. The FFmpeg route wins on
  batch control, folder mirroring and repeatability.
- **320 kbps** costs 25% more space for a difference nobody can reliably hear, especially
  from an MP3 source whose quality ceiling is already fixed.
- **ALAC** is the only M4A option with *zero* added loss. But you'd be storing an MP3's
  quality in a file 3–5× bigger than the MP3. It never sounds better than the original
  MP3, so if "zero added loss" is what you want, keeping the MP3 gets you that for free.

**Use AAC-LC 256 kbps.** It meets all your priorities: practically no added loss, the format
Apple itself sells, reasonable file sizes. Choose ALAC only if you insist on zero added
generation loss *and* must have M4A: run the script with `-Codec alac`.

---

## 4. Why MP3 → ALAC is not true lossless

MP3 is **lossy**. When the MP3 was made, the encoder permanently removed audio it judged
you wouldn't hear. That includes sounds masked by louder sounds, fine detail, and often
everything above ~16–19 kHz. That information isn't hidden in the file; it's gone.

Converting MP3 to ALAC means:
1. The MP3 is decoded to PCM: the MP3's *approximation* of the original recording.
2. ALAC stores that approximation perfectly.

So the ALAC file is lossless **relative to the MP3**, not relative to the original
recording. A spectrogram still shows the MP3's high-frequency cutoff and artefacts, and
the audio is identical to the MP3's. The only thing that changes is that the file is much bigger.

| | MP3 → M4A (this guide) | True lossless |
|---|---|---|
| Source | Already lossy MP3 | CD, FLAC, WAV, AIFF or ALAC from the original master |
| Best achievable result | *Preserve* the MP3's quality with minimal new loss | Bit-perfect copy of the original recording |
| Right format | AAC 256 (or ALAC for zero *added* loss, no gain) | ALAC (for Apple) |

For real lossless quality, go back to a lossless source: rip the CD
(e.g. iTunes with "Use error correction", or Exact Audio Copy), or buy/download
FLAC/ALAC. Then convert FLAC → ALAC with `ffmpeg -i song.flac -map 0 -c:a alac -c:v copy song.m4a`.

---

## 5. Installing FFmpeg on Windows (free)

### Option A: winget (Windows 10/11, easiest)
1. Right-click **Start** → **Terminal** (or **Windows PowerShell**).
2. Run:
   ```powershell
   winget install --id Gyan.FFmpeg -e
   ```
3. **Close the window and open a new one** so the updated PATH is picked up.
4. Check it:
   ```powershell
   ffmpeg -version
   ffprobe -version
   ```

### Option B: manual download
1. Go to <https://www.gyan.dev/ffmpeg/builds/> and download **ffmpeg-release-essentials.zip**.
2. Extract it and rename the folder to `C:\ffmpeg`, so that `C:\ffmpeg\bin\ffmpeg.exe` exists.
3. Start → type **"Edit environment variables for your account"** → select **Path** → **Edit** →
   **New** → `C:\ffmpeg\bin` → **OK** → **OK**.
4. Open a **new** PowerShell window and run `ffmpeg -version`.

### Get the scripts
1. Download this repository (GitHub → **Code** → **Download ZIP**) and extract it, e.g. to `C:\m4a-itunes`.
2. Unblock the downloaded scripts once (Windows marks downloaded files as untrusted):
   ```powershell
   Get-ChildItem C:\m4a-itunes\scripts\*.ps1 | Unblock-File
   ```

### Optional helpers (free)
- **Mp3tag**: best free tool for fixing tags and artwork *before* converting (bulk edit, add cover art).
- **foobar2000**: excellent for checking tags/artwork across thousands of files (see §11).

---

## 6. FFmpeg commands (copy and paste)

All commands keep tags and artwork. `-map "0:v:0?"` means "take the artwork if there is
any". The `?` stops files without artwork from failing.

### 6a. One MP3 → M4A (Command Prompt or PowerShell)
```bat
ffmpeg -i "My Song.mp3" -map 0:a:0 -map "0:v:0?" -map_metadata 0 -c:a aac -profile:a aac_low -b:a 256k -c:v copy -disposition:v:0 attached_pic -movflags +faststart "My Song.m4a"
```

### 6b. Every MP3 in one folder (Command Prompt, run inside the folder)
```bat
for %f in (*.mp3) do ffmpeg -hide_banner -nostdin -n -i "%f" -map 0:a:0 -map "0:v:0?" -map_metadata 0 -c:a aac -profile:a aac_low -b:a 256k -c:v copy -disposition:v:0 attached_pic -movflags +faststart "%~nf.m4a"
```
In a `.bat` file, write `%%f` and `%%~nf` instead of `%f` and `%~nf`.
`-n` = never overwrite, so re-running never creates or clobbers duplicates.

### 6c. Every MP3 in all subfolders, keeping the folder structure (Command Prompt)
This writes each `.m4a` **next to** its MP3:
```bat
for /r "D:\Music\MP3" %f in (*.mp3) do ffmpeg -hide_banner -nostdin -n -i "%f" -map 0:a:0 -map "0:v:0?" -map_metadata 0 -c:a aac -profile:a aac_low -b:a 256k -c:v copy -disposition:v:0 attached_pic -movflags +faststart "%~dpnf.m4a"
```
⚠️ With MP3 and M4A in the same folders, importing that folder into Apple Music imports
**both**, which gives you duplicates. The PowerShell version below writes to a **separate,
mirrored folder** instead, which is what I recommend.

### 6d. Preserving metadata and artwork: what each part does
| Option | Why |
|---|---|
| `-map 0:a:0` | the audio stream |
| `-map "0:v:0?"` | the embedded cover (ID3 `APIC`), if present |
| `-map_metadata 0` | copy all ID3 tags → iTunes MP4 tags |
| `-c:v copy` | keep the artwork byte-for-byte (no recompression) |
| `-disposition:v:0 attached_pic` | store it as cover art (`covr`), not as a video track |

**One catch the script handles for you:** if an MP3's artwork is BMP or GIF, the plain
commands above store it mislabelled as JPEG, and it shows up blank. The PowerShell
script detects that and converts such artwork to JPEG. For a single file, replace
`-c:v copy` with `-c:v mjpeg -q:v 2`.

---

## 7. PowerShell batch conversion (recommended)

### 7a. The script: whole library, mirrored folders, safe to re-run
```powershell
powershell -ExecutionPolicy Bypass -File C:\m4a-itunes\scripts\Convert-Mp3ToM4a.ps1 -Source "D:\Music\MP3" -Destination "D:\Music\M4A"
```
What it does:
- Finds every `.mp3` in `D:\Music\MP3` and all subfolders.
- Writes `D:\Music\M4A\<same subfolders>\<same name>.m4a`.
- Never modifies or deletes your MP3s.
- **Skips files that already exist**, so running it again after an interruption continues
  where it left off without duplicating anything (`-Overwrite` forces re-conversion).
- Writes to `*.m4a.part` first and renames on success, so there are no half-written files.
- Converts non-JPEG/PNG artwork to JPEG.
- Lists failures and writes them to `D:\Music\M4A\conversion-errors.log`.

ALAC instead of AAC: add `-Codec alac`. Different bitrate: `-Bitrate 320k`.

### 7b. Inline PowerShell (no script file)
Paste into PowerShell. Edit the two paths first; the source path must not end with `\`.
```powershell
$src = 'D:\Music\MP3'; $dst = 'D:\Music\M4A'
Get-ChildItem -LiteralPath $src -Recurse -File -Filter *.mp3 | ForEach-Object {
  $out = Join-Path $dst ([IO.Path]::ChangeExtension($_.FullName.Substring($src.Length).TrimStart('\'), '.m4a'))
  New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
  ffmpeg -hide_banner -nostdin -loglevel error -n -i $_.FullName -map 0:a:0 -map '0:v:0?' -map_metadata 0 -c:a aac -profile:a aac_low -b:a 256k -c:v copy -disposition:v:0 attached_pic -movflags +faststart $out
}
```
(It doesn't include the BMP/GIF artwork fix or the error log. Use the script for a whole library.)

### 7c. Verify the result
```powershell
powershell -ExecutionPolicy Bypass -File C:\m4a-itunes\scripts\Verify-M4aLibrary.ps1 -Source "D:\Music\MP3" -Destination "D:\Music\M4A"
```
For each MP3 it checks that the M4A exists, is AAC/ALAC, has the same duration, has the
same title/artist/album/album artist/track/disc/genre/date, and has artwork if the MP3 had
it. It also flags extra M4As, leftover `.part` files and duplicate songs. The report is saved as
`verify-report.csv` in the destination folder.

**Try it on one album first**, check it on your iPhone, then run the whole library.

---

## 8. Import into Apple Music / iTunes and sync to iPhone

On Windows 10/11 you can use either:
- **Apple Music app** (for the library) + **Apple Devices app** (for syncing), both free
  from the Microsoft Store, or
- **iTunes for Windows** (does both).

Note: once the Apple Music app is installed, iTunes no longer manages your music. Pick one.

### Step 1: Avoid duplicates before importing
If your MP3s are already in your library, remove them first or you'll have every song twice:
1. Go to **Songs** view, show the **Kind** column (right-click column header),
   sort by **Kind**, select all **"MPEG audio file"** entries.
2. Press **Delete** → **Delete from Library**, and when asked, **Keep File** (the MP3s stay on disk as your backup).

   Note: play counts, ratings and playlist membership belong to the old library entries
   and don't move to the new files automatically.

### Step 2: Choose where the files live
**Apple Music app:** ••• menu → **Settings → Files**. **iTunes:** **Edit → Preferences → Advanced**.
- **"Copy files to … Media folder when adding to library"**
  - **Off** (recommended): the library points at `D:\Music\M4A`. Don't move or rename that folder afterwards.
  - **On**: Apple Music makes its own copy. Doubles disk use until you delete `D:\Music\M4A`.

### Step 3: Import
- **Apple Music app:** ••• menu at the top of the sidebar → **File → Import…** → choose `D:\Music\M4A`.
- **iTunes:** **File → Add Folder to Library…** → choose `D:\Music\M4A`.

Import **only** the M4A folder, never the MP3 folder too.

### Step 4: Sync to iPhone (USB cable)
1. On the iPhone: **Settings → Apps → Music** (older iOS: **Settings → Music**) → turn **Sync Library OFF**.
   Cable sync of music is blocked while it's on (see §10).
2. Connect the iPhone with USB, unlock it, tap **Trust**.
3. **Apple Devices app:** select the iPhone → **Music** → tick **Sync music onto [iPhone]**.
   **iTunes:** click the phone icon → **Music** → tick **Sync Music**.
4. Choose **Entire music library** or **Selected artists, albums, genres and playlists**.
5. Click **Apply** / **Sync** and wait for it to finish before unplugging.

*With an Apple Music or iTunes Match subscription:* you can leave **Sync Library ON** on both
PC and iPhone instead. Your M4As upload to iCloud and appear on the phone over the internet
(slower, and matched songs may use Apple's catalogue copy and artwork).

---

## 9. Verification checklist

**On the PC**
- [ ] `Convert-Mp3ToM4a.ps1` ends with `Failed: 0` (or you've reviewed `conversion-errors.log`).
- [ ] `Verify-M4aLibrary.ps1` reports `Issues: 0`; the MP3 and M4A counts match.
- [ ] No `*.m4a.part` files remain in the destination folder.
- [ ] In File Explorer, right-click a few M4As → **Properties → Details**: bit rate ≈ 256 kbps, title/artist/album are filled in.
- [ ] Your original MP3 folder is untouched (same file count as before).

**In Apple Music / iTunes**
- [ ] Songs view: add the **Kind**, **Bit Rate**, **Sample Rate**, **Album Artist**, **Track #**, **Disc #**, **Genre**, **Year** columns. Kind = **AAC audio file** (or Apple Lossless), 44.100 kHz, ~256 kbps.
- [ ] Albums view: every album shows its cover, and no album is split in two.
- [ ] **Get Info** (right-click a song → *Song Info*) → **Artwork** tab shows the cover.
- [ ] Song count = number of MP3s you converted (Songs view shows the total).
- [ ] No duplicates: sort Songs by **Name** and scan a few popular artists. In iTunes: **File → Library → Show Duplicate Items** (hold **Shift** for *Show Exact Duplicate Items*). Sort by **Kind** and check that no "MPEG audio file" entries remain.
- [ ] Play several tracks from start to finish, including the first seconds and the ending.

**On the iPhone**
- [ ] Music app → **Library → Songs**: the count matches the synced selection.
- [ ] Open several albums: cover art, track order and disc grouping are correct.
- [ ] Play songs with **Airplane Mode ON** to prove they're stored on the phone, not streamed.
- [ ] Search for one or two artists: each song appears once.

---

## 10. Common errors and fixes

### Missing artwork
| Cause | Fix |
|---|---|
| The MP3 never had embedded art (only a `folder.jpg` next to it) | Add it to the MP3s with Mp3tag (select album → right-click cover area → *Add cover*) and re-convert, or add it to the M4A: `ffmpeg -i "in.m4a" -i "cover.jpg" -map 0:a -map 1:v -map_metadata 0 -c copy -disposition:v:0 attached_pic -movflags +faststart "out.m4a"` |
| Art was BMP/GIF → stored mislabelled by the plain FFmpeg command | Use the PowerShell script (it converts to JPEG), or use `-c:v mjpeg -q:v 2` instead of `-c:v copy` |
| Art is in the file but Apple Music shows grey notes | Its artwork cache is stale: select the album → **Get Info → Artwork → Add Artwork**, or remove the songs from the library (keep files) and re-import |
| Some songs of an album have art, some don't | Different songs had different/no art. Fix in Mp3tag, re-convert with `-Overwrite` |
| Art correct on PC, missing on iPhone | Unsync that album, sync, re-sync it. Very large images (several MB) can be slow; resize to ~1000–1400 px with Mp3tag if it persists |

### "Unsupported codec" and other FFmpeg errors
| Message | Fix |
|---|---|
| `'ffmpeg' is not recognized…` | FFmpeg isn't on PATH, or you're using a window that was open before installing it. Open a new window (§5) |
| `running scripts is disabled on this system` | Use the `powershell -ExecutionPolicy Bypass -File …` form shown above, or run `Unblock-File` on the scripts |
| `Unknown encoder 'libfdk_aac'` | Normal Windows builds don't include it. Use `-c:a aac` as shown |
| `codec not currently supported in container` | You used `-c:a copy` (MP3 audio can't go in an iTunes M4A) or mapped extra streams. Use the exact commands above |
| `Invalid data found when processing input` / `Failed to find two consecutive MPEG audio frames` | The file is damaged or isn't really an MP3 (e.g. a renamed WMA/WAV). Check with `ffprobe "file.mp3"`; replace the file or convert from what it really is |
| `File '…m4a' already exists. Exiting.` | Expected when re-running with `-n`: it's protecting existing output |
| Artwork causes an error with a file that has several pictures | The commands take only the first picture (`0:v:0`). Clean up extra images in Mp3tag if the first isn't the front cover |

### Duplicate library entries
| Cause | Fix |
|---|---|
| MP3s were already in the library | Delete the "MPEG audio file" entries from the library, **Keep File** (§8 Step 1) |
| Imported a folder that contains both MP3 and M4A | Convert into a separate folder (script) and import only that |
| Imported the same folder twice, or "Copy files to Media folder" was on and you imported the Media folder too | Remove duplicates (iTunes: File → Library → Show Duplicate Items), then import only once |
| Duplicate files on disk (`Song 1.m4a`, `Song (1).m4a`) | `Verify-M4aLibrary.ps1` lists them as **DUPLICATE/EXTRA**; delete the extras |
| One album shows up as several albums | Inconsistent **Album Artist**, **Album** spelling or **Compilation** flag. Fix in Mp3tag (set one Album Artist for the whole album) and re-convert with `-Overwrite` |

### Songs won't sync
| Cause | Fix |
|---|---|
| "Sync Library" (iCloud Music Library) is on | iPhone **Settings → Apps → Music → Sync Library OFF**, or use cloud sync instead (§8) |
| iPhone not visible | Unlock the phone, tap **Trust**, try another cable/port, update Apple Devices/iTunes and Windows |
| Songs have a **!** icon | Apple Music can't find the file (folder moved/renamed). Put it back, or remove the entries and re-import |
| Some songs skipped | In iTunes, **"Sync only checked songs and videos"** is on and they're unchecked. Check them or turn the option off |
| "Not enough space" | Sync selected albums/playlists instead of the whole library |
| Song plays on PC but not iPhone | Run `ffprobe` on it: audio must be `aac` or `alac` in an `.m4a`. Re-convert with the script |

---

## 11. When iTunes or foobar2000 are the better tool

- **FFmpeg + this script: the main workflow.** Free, scriptable, mirrors your folders,
  safe to re-run, and you can verify the results. Tags and artwork were verified in testing.
- **iTunes / Apple Music "Create AAC Version":** uses Apple's own AAC encoder in true
  256 kbps VBR (iTunes Plus). Set **Import Settings → AAC Encoder → iTunes Plus**, select songs → **File → Convert → Create AAC Version**.
  Good for a handful of songs, but for a whole library it's awkward: it puts the new
  files in the Media folder, adds a second entry next to every MP3 (so you must delete the MP3
  entries), can't mirror your folder structure, and is slow to check.
  The quality difference against FFmpeg at 256 kbps from an MP3 source isn't audible in practice.
- **foobar2000 (free):** best for *auditing* a large library: load the folder and use the
  columns and **Properties** dialog to spot missing tags and art. It can also convert with
  Apple's AAC encoder via the separate *qaac* tool, but that needs extra Apple
  components and setup. Only worth it if you specifically want Apple's encoder and a GUI.
- **Mp3tag (free):** the best place to fix tags and artwork *before* converting, so the M4As come out right.

---

## Files in this repo

| File | Purpose |
|---|---|
| `scripts/Convert-Mp3ToM4a.ps1` | Batch-convert a library, mirror the folders, keep tags and art, skip existing files |
| `scripts/Verify-M4aLibrary.ps1` | Compare the MP3 and M4A trees: tags, art, duration, codec, missing/extra/duplicate files |

Both scripts work in Windows PowerShell 5.1 (built into Windows) and PowerShell 7.
