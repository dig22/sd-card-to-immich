#!/usr/bin/env python3
"""sd2immich: import a camera SD card into Immich, RAW-first, deduplicated, one album per day.

Rules
  * For every shot (DSC01234.ARW + DSC01234.JPG) only the RAW is uploaded.
  * A JPG is uploaded only when its shot has no RAW, and never if that shot's RAW was
    imported on an earlier run (local ledger keyed by file name + capture time, because
    camera file numbers repeat).
  * Videos (DCIM and Sony's PRIVATE/M4ROOT/CLIP) are imported too, unless --no-videos.
  * Anything already in Immich (same SHA-1) is not uploaded again, but still goes into
    its day album. Albums are named from the capture date (default YYYY-MM-DD) and are
    reused if they exist.

Usage
  sd2immich.py                 import from the camera card that is mounted
  sd2immich.py --dry-run       show what would happen
  sd2immich.py --set-key       store the Immich API key (read from stdin) in Keychain
  sd2immich.py --summary       JSON: mounted camera cards and what is on them (no network)
  sd2immich.py --check         JSON: test server + API key

--json switches all output to JSON lines (one event per line); the macOS app uses it.

Config: ~/.config/sd2immich/config.json (see config.example.json; the app writes it).
API key: login Keychain, service "sd2immich". Permissions: user.read, asset.upload,
album.read, album.create, albumAsset.create.
"""

from __future__ import annotations  # macOS's own /usr/bin/python3 is 3.9

import argparse
import collections
import datetime as dt
import hashlib
import json
import os
import shlex
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

APP_NAME = "SD to Immich"
CONFIG_FILE = Path.home() / ".config/sd2immich/config.json"
STATE_DIR = Path.home() / "Library/Application Support/sd2immich"
LEDGER = STATE_DIR / "raw-shots.json"
KEYCHAIN_SERVICE = "sd2immich"
DEVICE_ID = "sd2immich"

RAW_EXT = {".ARW", ".SR2", ".DNG", ".CR3", ".CR2", ".NEF", ".NRW", ".RAF", ".ORF", ".RW2", ".PEF"}
JPG_EXT = {".JPG", ".JPEG", ".HEIC", ".HIF"}
VIDEO_EXT = {".MP4", ".MOV", ".MTS", ".M2TS", ".AVI"}
VIDEO_DIRS = ["PRIVATE/M4ROOT/CLIP", "PRIVATE/AVCHD/BDMV/STREAM"]  # Sony keeps clips outside DCIM

DEFAULTS = {
    "server": "",               # e.g. https://immich.example.com (no /api)
    "album_format": "%Y-%m-%d",
    "videos": True,
    "raw_only": False,
    # Immich (Node) drops an upload that takes more than ~5 minutes to arrive. If your
    # link to Immich is slow, set relay_host to an ssh host near Immich (with rsync and
    # curl): files bigger than relay_min_mb are rsynced there (resumable) and uploaded
    # from it. Leave empty to always upload directly.
    "relay_host": "",
    "relay_dir": ".cache/sd2immich",
    "relay_min_mb": 300,
}


def load_config() -> dict:
    cfg = dict(DEFAULTS)
    if CONFIG_FILE.exists():
        cfg.update(json.loads(CONFIG_FILE.read_text()))
    if not cfg["server"]:
        die(f"Set \"server\" in {CONFIG_FILE} (run install.sh).")
    cfg["api"] = cfg["server"].rstrip("/") + "/api"
    return cfg


JSON_OUT = False


def emit(kind: str, text: str = "", **data) -> None:
    """One progress event: a JSON line for the app, or plain text for humans."""
    if JSON_OUT:
        print(json.dumps({"type": kind, "text": text, **data}), flush=True)
    elif text:
        print(text, file=sys.stderr if kind == "error" else sys.stdout, flush=True)


def die(msg: str):
    emit("error", msg)
    sys.exit(1)


# --- macOS bits ------------------------------------------------------------------

def osascript(script: str) -> str:
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return r.stdout.strip()


def notify(msg: str) -> None:
    osascript(f"display notification {json.dumps(msg)} with title {json.dumps(APP_NAME)}")


def api_key() -> str:
    if os.environ.get("IMMICH_API_KEY"):
        return os.environ["IMMICH_API_KEY"]
    r = subprocess.run(["security", "find-generic-password", "-a", os.environ["USER"],
                        "-s", KEYCHAIN_SERVICE, "-w"], capture_output=True, text=True)
    if r.returncode:
        die("No Immich API key in Keychain: run install.sh or `sd2immich.py --set-key`.")
    return r.stdout.strip()


def camera_cards() -> list[Path]:
    """Mounted volumes that look like camera cards (have a DCIM folder)."""
    vols = Path("/Volumes")
    return sorted(v for v in vols.iterdir() if v.is_dir() and not v.is_symlink() and (v / "DCIM").is_dir())


# --- EXIF capture date ------------------------------------------------------------
# RAW files are TIFF-based and JPEGs carry a TIFF block in APP1, so one small IFD walker
# covers both: IFD0 -> ExifIFD (0x8769) -> DateTimeOriginal (0x9003).

def _tiff_date(buf: bytes, base: int) -> str | None:
    order = {b"II": "<", b"MM": ">"}.get(buf[base:base + 2])
    if not order:
        return None

    def ifd_entries(off):
        (n,) = struct.unpack_from(order + "H", buf, base + off)
        for i in range(n):
            yield struct.unpack_from(order + "HHII", buf, base + off + 2 + 12 * i)

    (ifd0,) = struct.unpack_from(order + "I", buf, base + 4)
    exif_off = next((v for t, _, _, v in ifd_entries(ifd0) if t == 0x8769), None)
    for off in filter(None, (exif_off, ifd0)):
        for tag, typ, cnt, val in ifd_entries(off):
            if tag in (0x9003, 0x0132) and typ == 2 and cnt >= 19:  # DateTimeOriginal / DateTime
                return buf[base + val:base + val + 19].decode("ascii", "replace")
    return None


def capture_time(path: Path) -> dt.datetime:
    stamp = None
    if path.suffix.upper() not in VIDEO_EXT:
        with open(path, "rb") as f:
            head = f.read(256 * 1024)
        try:
            if head[:2] == b"\xff\xd8":  # JPEG: find the Exif APP1 segment
                i = head.find(b"Exif\x00\x00")
                if i > 0:
                    stamp = _tiff_date(head, i + 6)
            else:
                stamp = _tiff_date(head, 0)
        except struct.error:
            stamp = None
    if stamp:
        try:
            return dt.datetime.strptime(stamp, "%Y:%m:%d %H:%M:%S")
        except ValueError:
            pass
    return dt.datetime.fromtimestamp(path.stat().st_mtime)  # cameras write local time


# --- Immich API -------------------------------------------------------------------

class Immich:
    def __init__(self, cfg: dict, key: str):
        self.cfg, self.api, self.key = cfg, cfg["api"], key

    def call(self, method: str, path: str, body=None, data: bytes | None = None, ctype=None):
        headers = {"x-api-key": self.key, "Accept": "application/json"}
        if body is not None:
            data, ctype = json.dumps(body).encode(), "application/json"
        if ctype:
            headers["Content-Type"] = ctype
        req = urllib.request.Request(self.api + path, data=data, headers=headers, method=method)
        for attempt in range(6):  # a busy server (RAW thumbnailing) drops connections now and then
            try:
                with urllib.request.urlopen(req, timeout=600) as r:
                    raw = r.read()
                return json.loads(raw) if raw else None
            except urllib.error.HTTPError as e:
                if e.code < 500 or attempt == 5:
                    die(f"{method} {path} -> {e.code}: {e.read().decode()[:300]}")
            except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
                if attempt == 5:
                    raise
                emit("log", f"    {e}; retrying in {15 * (attempt + 1)}s")
            time.sleep(15 * (attempt + 1))

    @staticmethod
    def fields(path: Path, created: dt.datetime) -> dict:
        # Immich needs an offset; camera times are local, so attach this Mac's zone.
        mtime = dt.datetime.fromtimestamp(path.stat().st_mtime).astimezone().isoformat()
        return {"deviceAssetId": f"{path.name}-{path.stat().st_size}", "deviceId": DEVICE_ID,
                "fileCreatedAt": created.astimezone().isoformat(), "fileModifiedAt": mtime,
                "filename": path.name}

    def upload(self, path: Path, created: dt.datetime) -> dict:
        if self.cfg["relay_host"] and path.stat().st_size > self.cfg["relay_min_mb"] * 1024 * 1024:
            return self.upload_via_relay(path, created)
        boundary = uuid.uuid4().hex
        parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
                 for k, v in self.fields(path, created).items()]
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="assetData"; '
                     f'filename="{path.name}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode())
        body = b"".join(parts) + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
        return self.call("POST", "/assets", data=body, ctype=f"multipart/form-data; boundary={boundary}")

    def upload_via_relay(self, path: Path, created: dt.datetime) -> dict:
        host, rdir = self.cfg["relay_host"], self.cfg["relay_dir"]
        emit("log", f"    {path.stat().st_size / 1e9:.1f} GB: copying to {host} first (resumable)...")
        ssh = ["ssh", "-o", "ServerAliveInterval=30", "-o", "BatchMode=yes", host]
        subprocess.run([*ssh, f"mkdir -p {shlex.quote(rdir)}"], check=True)
        remote = f"{rdir}/{path.name}"
        for _ in range(5):
            if subprocess.run(["rsync", "--partial", "--inplace", "--times", str(path), f"{host}:{remote}"],
                              stdout=subprocess.DEVNULL).returncode == 0:
                break
            emit("log", "    rsync failed; retrying in 20s")
            time.sleep(20)
        else:
            die(f"Could not copy {path.name} to {host}")
        form = " ".join(f"-F {shlex.quote(f'{k}={v}')}" for k, v in self.fields(path, created).items())
        # The key goes over ssh stdin as a header, so it never lands on the relay's disk or argv.
        cmd = (f"curl -sS --fail-with-body -X POST {shlex.quote(self.api + '/assets')} -H @- {form} "
               f"-F assetData=@{shlex.quote(remote)}; rc=$?; rm -f {shlex.quote(remote)}; exit $rc")
        r = subprocess.run([*ssh, cmd], input=f"x-api-key: {self.key}\n", capture_output=True, text=True)
        if r.returncode:
            die(f"Upload of {path.name} via {host} failed: {(r.stdout + r.stderr)[:300]}")
        return json.loads(r.stdout)


# --- picking files ----------------------------------------------------------------

def shot_key(path: Path, taken: dt.datetime) -> str:
    return f"{path.stem.upper()}|{taken.isoformat(timespec='seconds')}"


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def save_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=0))
    tmp.replace(path)


def pick_files(card: Path, videos: bool, raw_only: bool = False) -> list[Path]:
    shots = collections.defaultdict(dict)
    clips = []
    for root, _, files in os.walk(card / "DCIM"):
        for f in files:
            if f.startswith("._"):
                continue
            p = Path(root) / f
            ext = p.suffix.upper()
            if ext in VIDEO_EXT:
                clips.append(p)
            elif ext in RAW_EXT | JPG_EXT:
                shots[(root, p.stem)][ext] = p
    chosen = []
    for exts in shots.values():
        raw = [p for e, p in exts.items() if e in RAW_EXT]
        jpg = [p for e, p in exts.items() if e in JPG_EXT]
        chosen += raw or ([] if raw_only else jpg)
    if videos:
        for d in VIDEO_DIRS:
            clips += [p for p in (card / d).glob("*") if p.suffix.upper() in VIDEO_EXT and not p.name.startswith("._")]
        chosen += clips
    return sorted(chosen)


def counts(files: list[Path]) -> dict:
    return {"raw": sum(p.suffix.upper() in RAW_EXT for p in files),
            "jpg": sum(p.suffix.upper() in JPG_EXT for p in files),
            "videos": sum(p.suffix.upper() in VIDEO_EXT for p in files),
            "bytes": sum(p.stat().st_size for p in files)}


def describe(files: list[Path]) -> str:
    c = counts(files)
    bits = [f"{c['raw']} RAW"] + ([f"{c['jpg']} JPG (no RAW)"] if c["jpg"] else []) \
        + ([f"{c['videos']} videos"] if c["videos"] else [])
    return ", ".join(bits) + f" ({c['bytes'] / 1e9:.1f} GB)"


def sha1(path: Path) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- commands ---------------------------------------------------------------------

def import_card(cfg: dict, card: Path, a) -> str:
    files = pick_files(card, videos=cfg["videos"] and not a.no_videos, raw_only=a.raw_only or cfg["raw_only"])
    if not files:
        return f"No photos or videos on {card.name}."
    emit("scan", f"Scanning {card}: {describe(files)} ...", card=str(card), total=len(files))
    info = {}
    for n, p in enumerate(files, 1):
        info[p] = (sha1(p), capture_time(p))
        emit("hashing", n=n, total=len(files), file=p.name)

    ledger = set(load_json(LEDGER, []))
    known_raw = [p for p, (_, t) in info.items() if p.suffix.upper() in JPG_EXT and shot_key(p, t) in ledger]
    for p in known_raw:
        del info[p]
    if known_raw:
        emit("log", f"  skipping {len(known_raw)} JPG(s) whose RAW was imported earlier")
    if not info:
        return "Nothing new to import."

    first_by_hash: dict[str, Path] = {}
    for p, (h, _) in info.items():
        first_by_hash.setdefault(h, p)

    imm = Immich(cfg, api_key())
    me = imm.call("GET", "/users/me")
    emit("log", f"Immich: {cfg['server']} as {me.get('name') or me.get('email')}")

    results = {}
    hashes = list(first_by_hash.items())
    for i in range(0, len(hashes), 200):
        res = imm.call("POST", "/assets/bulk-upload-check",
                       {"assets": [{"id": h, "checksum": h} for h, _ in hashes[i:i + 200]]})
        results.update({r["id"]: r for r in res["results"]})

    to_upload = [p for h, p in hashes if results[h]["action"] == "accept"]
    dupes = {h: r["assetId"] for h, r in results.items() if r["action"] == "reject" and r.get("assetId")}
    album_of = {p: t.strftime(cfg["album_format"]) for p, (_, t) in info.items()}
    by_album = collections.Counter(album_of.values())
    emit("plan", f"  new: {len(to_upload)}   already in Immich: {len(dupes)}   "
                 f"duplicates on card: {len(info) - len(first_by_hash)}\n"
                 "  albums: " + ", ".join(f"{d} ({n})" for d, n in sorted(by_album.items())),
         new=len(to_upload), existing=len(dupes), albums=dict(sorted(by_album.items())),
         bytes=sum(p.stat().st_size for p in to_upload))
    if a.dry_run:
        return f"Dry run: {len(to_upload)} new, {len(dupes)} already in Immich."

    asset_of_hash = dict(dupes)
    raw_keys = {h: shot_key(p, t) for p, (h, t) in info.items() if p.suffix.upper() in RAW_EXT}
    ledger |= {raw_keys[h] for h in dupes if h in raw_keys}
    save_json(LEDGER, sorted(ledger))

    total = sum(p.stat().st_size for p in to_upload) or 1
    done = 0
    for n, p in enumerate(to_upload, 1):
        r = imm.upload(p, info[p][1])
        h = info[p][0]
        asset_of_hash[h] = r["id"]
        if h in raw_keys:
            ledger.add(raw_keys[h])
            save_json(LEDGER, sorted(ledger))
        done += p.stat().st_size
        emit("progress", f"  [{n}/{len(to_upload)}] {p.name} {r['status']}  ({done / total:.0%})",
             n=n, total=len(to_upload), file=p.name, status=r["status"], fraction=done / total)

    albums = {al["albumName"]: al["id"] for al in imm.call("GET", "/albums")}
    album_assets = collections.defaultdict(set)
    for p, (h, _) in info.items():
        if h in asset_of_hash:
            album_assets[album_of[p]].add(asset_of_hash[h])
    for name, ids in sorted(album_assets.items()):
        if name in albums:
            res = imm.call("PUT", f"/albums/{albums[name]}/assets", {"ids": sorted(ids)})
            added = sum(1 for x in res if x.get("success"))
            emit("album", f"  album {name}: +{added} ({len(ids) - added} were already in it)", name=name)
        else:
            imm.call("POST", "/albums", {"albumName": name, "assetIds": sorted(ids)})
            emit("album", f"  album {name}: created with {len(ids)}", name=name)
    return f"Imported {len(to_upload)} new item(s) from {card.name} into {len(album_assets)} album(s)."


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--card", type=Path, help="card mount point (default: the mounted card with a DCIM folder)")
    ap.add_argument("--dry-run", action="store_true", help="show what would be imported, change nothing")
    ap.add_argument("--no-videos", action="store_true", help="photos only")
    ap.add_argument("--raw-only", action="store_true", help="also skip JPGs that have no RAW")
    ap.add_argument("--notify", action="store_true", help="macOS notification when done")
    ap.add_argument("--set-key", action="store_true", help="store the Immich API key from stdin in Keychain")
    ap.add_argument("--summary", action="store_true", help="JSON: mounted camera cards and their contents")
    ap.add_argument("--check", action="store_true", help="JSON: test the server URL and API key")
    ap.add_argument("--json", action="store_true", help="JSON-lines progress output")
    a = ap.parse_args()
    global JSON_OUT
    JSON_OUT = a.json or a.summary or a.check

    if a.summary:
        cfg = dict(DEFAULTS, **load_json(CONFIG_FILE, {}))
        cards = []
        for c in ([a.card] if a.card else camera_cards()):
            files = pick_files(c, videos=cfg["videos"] and not a.no_videos, raw_only=a.raw_only or cfg["raw_only"])
            cards.append({"path": str(c), "name": c.name, **counts(files)})
        print(json.dumps({"cards": cards}))
        return

    if a.set_key:
        key = sys.stdin.readline().strip()
        if not key:
            die("Pipe the API key on stdin.")
        subprocess.run(["security", "add-generic-password", "-U", "-a", os.environ["USER"],
                        "-s", KEYCHAIN_SERVICE, "-w", key], check=True)
        print("Immich API key stored in Keychain.")
        return

    cfg = load_config()
    if a.check:
        me = Immich(cfg, api_key()).call("GET", "/users/me")
        emit("ok", f"Connected as {me.get('name') or me.get('email')}", user=me.get("name") or me.get("email"))
        return
    if a.card:
        cards = [a.card]
    else:
        cards = camera_cards()
        if not cards:
            die("No camera card mounted (looking for /Volumes/*/DCIM).")
    try:
        msgs = [import_card(cfg, c, a) for c in cards]
    except SystemExit:
        if a.notify:
            notify("Import failed. See the Terminal window.")
        raise
    for m in msgs:
        emit("done", m)
    if a.notify:
        notify(" ".join(msgs))


if __name__ == "__main__":
    main()
