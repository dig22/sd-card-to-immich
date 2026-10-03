# SD to Immich: import camera SD cards into Immich on macOS

**SD to Immich** is a free, open-source Mac app that imports photos and videos from a camera SD card into your self-hosted [Immich](https://immich.app) server: **RAW-first, with no duplicates, sorted into albums by date.**

Insert the card, click **Import to Immich**, done. The app uploads the RAW file of every shot (Sony ARW, Canon CR3/CR2, Nikon NEF, Fujifilm RAF, Olympus ORF, Panasonic RW2, Pentax PEF, DNG), skips the matching JPEG, skips anything that is already in your Immich library, and puts each photo and video into an album named after the day it was taken.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#download)
[![Immich](https://img.shields.io/badge/Immich-v3-4250af)](https://immich.app)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

## Features

- **RAW + JPEG handled properly.** If you shoot RAW+JPEG, only the RAW is uploaded. A JPEG is uploaded only when a shot has no RAW. A JPEG whose RAW you imported on an earlier day is never uploaded later, even from a different card.
- **No duplicates.** Every file is checked against your Immich library by SHA-1 checksum before upload, so re-inserting a card or importing an overlapping card uploads only what is new.
- **Albums by capture date.** Photos and videos go into albums like `2026-10-02` (format configurable, e.g. `02 Oct 2026`), taken from the EXIF date. Existing albums are reused.
- **Videos included.** MP4/MOV/MTS clips from `DCIM` and from Sony's `PRIVATE/M4ROOT/CLIP` folder (Sony Alpha, ZV-E10, ZV-1, FX30, A7 series, …).
- **Native SwiftUI app.** Detects a camera card as soon as you insert it, shows what is on it, live progress, a notification when done, and an Eject button.
- **Large videos that actually upload.** Immich drops uploads that take more than ~5 minutes. On a slow link (VPN, Tailscale relay, Wi-Fi), big files can go through an optional SSH relay near your server: copied with `rsync` (resumable) and uploaded from there.
- **Safe settings.** Your Immich API key lives in the macOS Keychain, never in a file. Nothing is deleted from the card.
- **Works from the command line too** (`sd2immich.py`), for scripts and automation.

## Download

1. Download `SD-to-Immich-x.y.z.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move **SD to Immich.app** to your Applications folder.
3. The app is open source but not notarized by Apple, so macOS blocks the first launch. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. (Or run `xattr -dr com.apple.quarantine "/Applications/SD to Immich.app"`.)

Requirements: macOS 13 Ventura or newer (Apple Silicon or Intel), and Python 3. macOS ships Python 3 with the Command Line Tools (`xcode-select --install`); Homebrew or python.org Python also work.

## Setup

1. In Immich, open **Account Settings → API Keys → New API Key** and grant:
   `user.read`, `asset.upload`, `album.read`, `album.create`, `albumAsset.create`.
2. Open **SD to Immich → Settings**, enter your Immich address (e.g. `https://photos.example.com`) and paste the key.
3. Click **Test connection**, then **Save**.

Now insert a camera card. It appears in the sidebar. Click **Check what's new** for a dry run, or **Import to Immich**.

## How it works

| Step | What happens |
|---|---|
| Find the card | Any mounted volume with a `DCIM` folder is treated as a camera card. |
| Pick files | Group files by shot (`DSC01234.ARW` + `DSC01234.JPG`). Keep the RAW; keep the JPEG only if there is no RAW. Add videos. |
| Deduplicate | Hash every file and ask Immich (`/assets/bulk-upload-check`) which ones it already has. |
| Upload | Upload only the new files, with their capture date. |
| Albums | Add every item (new or already uploaded) to its date album, creating the album if needed. |

The RAW ledger (`~/Library/Application Support/sd2immich/raw-shots.json`) remembers which RAW shots were imported, so their JPEG twins are skipped on later imports even if the RAW was deleted from the card.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| Server URL | | Your Immich address, without `/api` |
| API key | | Stored in the login Keychain (service `sd2immich`) |
| Import videos | on | Include video clips |
| RAW only | off | Also skip JPEGs that have no RAW |
| Album name format | `%Y-%m-%d` | strftime format of the capture date |
| Relay SSH host | empty | Optional `user@host` near Immich for big files |
| Relay threshold | 300 MB | Files above this go through the relay |

Settings other than the key are stored in `~/.config/sd2immich/config.json` (readable only by you). See [`config.example.json`](config.example.json).

## Command line

The app's engine is a single Python 3 file with no dependencies:

```sh
# store the key once (reads stdin)
pbpaste | python3 sd2immich.py --set-key

python3 sd2immich.py --dry-run        # what would be imported from the mounted card
python3 sd2immich.py                  # import
python3 sd2immich.py --card /Volumes/Untitled --no-videos
python3 sd2immich.py --check          # test server + key
```

## FAQ

**Does it delete or change anything on the SD card?**
No. It only reads. Format the card in your camera when you are ready.

**Why is the JPEG skipped when I shoot RAW+JPEG?**
Immich shows RAW files with previews, and keeping both doubles the library with near-identical images. Turn on "RAW only" to skip JPEG-only shots as well.

**What happens if I import the same card twice?**
Nothing is uploaded twice. Items already in Immich are skipped and just added to their album if they are missing from it.

**Big videos fail with "broken pipe" / the upload stops at ~5 minutes.**
That is Immich's request timeout on a slow connection. Use a faster network to the server, or set a relay SSH host in Settings.

**Which cameras are supported?**
Any camera that writes a standard `DCIM` folder. Sony's separate video folder is supported. Tested with a Sony ZV-E10 II and Immich v3.2.

**Is this an official Immich app?**
No. It is an independent project that uses Immich's public API.

## Build from source

```sh
git clone https://github.com/dig22/sd-card-to-immich.git
cd sd-card-to-immich
./build.sh 1.0.0      # needs Xcode or the Command Line Tools
open "build/SD to Immich.app"
```

## License

[MIT](LICENSE)
