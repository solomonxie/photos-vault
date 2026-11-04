"""Reads every photo and video in the given zips (Google Photos downloads)
without uploading anything: when each was taken, its size, and whether the
library already has it. Writes $WORK/survey.jsonl and prints the counts.

Already in the library: same pixel size and the same moment, allowing for
the camera's clock being in another whole-hour time zone (EXIF dates carry
no zone). Usage: survey.py LIBRARY_DB ZIP..."""

import hashlib
import io
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone

from PIL import Image

WORK = os.environ.get("WORK", "/tmp/zip-import")
STILL = {"jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff"}
VIDEO = {"mp4", "mov", "m4v"}
NAME_DATE = re.compile(r"(20\d\d|19\d\d)[-_]?(\d\d)[-_]?(\d\d)[-_ T]?(\d\d)[-_.]?(\d\d)[-_.]?(\d\d)")


def exif_date(img):
    exif = img.getexif()
    raw = exif.get_ifd(0x8769).get(36867) or exif.get(306)
    if not raw:
        return None
    try:
        return datetime.strptime(str(raw).strip()[:19], "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None


def still_meta(data):
    with Image.open(io.BytesIO(data)) as img:
        w, h = img.size
        try:
            orient = img.getexif().get(274, 1)
        except Exception:
            orient = 1
        if orient in (5, 6, 7, 8):
            w, h = h, w
        return exif_date(img), w, h


def video_meta(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height:stream_tags=rotate:format_tags=creation_time",
         "-of", "json", path], capture_output=True, text=True).stdout
    j = json.loads(out or "{}")
    s = (j.get("streams") or [{}])[0]
    w, h = s.get("width"), s.get("height")
    if str((s.get("tags") or {}).get("rotate", "0")) in ("90", "270") and w and h:
        w, h = h, w
    t = (j.get("format", {}).get("tags") or {}).get("creation_time")
    when = None
    if t:
        try:
            when = datetime.fromisoformat(t.replace("Z", "+00:00"))
        except ValueError:
            pass
    return when, w, h


def name_date(name):
    m = NAME_DATE.search(name)
    if not m:
        return None
    try:
        return datetime(*map(int, m.groups()))
    except ValueError:
        return None


def library(db):
    by_dims = {}
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    for created, w, h, video in con.execute(
            "SELECT created_at, width, height, is_video FROM asset_record "
            "WHERE deleted_at IS NULL AND width > 0 AND height > 0"):
        by_dims.setdefault((min(w, h), max(w, h), video), []).append(created // 1000)
    return by_dims


def in_library(by_dims, when, w, h, video, aware):
    if not when or not w or not h:
        return False
    secs = by_dims.get((min(w, h), max(w, h), int(video)), [])
    t = int((when if aware else when.replace(tzinfo=timezone.utc)).timestamp())
    for s in secs:
        d = abs(s - t)
        if aware:
            if d <= 2:
                return True
        elif d <= 14 * 3600 + 2 and min(d % 1800, 1800 - d % 1800) <= 2:
            return True
    return False


def main():
    db, zips = sys.argv[1], sys.argv[2:]
    os.makedirs(WORK, exist_ok=True)
    by_dims = library(db)
    seen = set()
    out = open(os.path.join(WORK, "survey.jsonl"), "w")
    counts = {}
    for z in zips:
        with zipfile.ZipFile(z) as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                ext = info.filename.rsplit(".", 1)[-1].lower()
                kind = "still" if ext in STILL else "video" if ext in VIDEO else None
                row = {"zip": z, "name": info.filename, "size": info.file_size, "kind": kind}
                if kind is None:
                    row["status"] = "skip-type"
                else:
                    h = hashlib.sha256()
                    when = w = hh = None
                    aware = False
                    try:
                        if kind == "still":
                            data = zf.read(info)
                            h.update(data)
                            when, w, hh = still_meta(data)
                        else:
                            with tempfile.NamedTemporaryFile(suffix="." + ext) as tmp:
                                with zf.open(info) as src:
                                    for chunk in iter(lambda: src.read(1 << 20), b""):
                                        h.update(chunk)
                                        tmp.write(chunk)
                                tmp.flush()
                                when, w, hh = video_meta(tmp.name)
                                aware = when is not None
                    except Exception as e:
                        row["error"] = str(e)[:120]
                    digest = h.hexdigest()
                    source = "camera" if when else None
                    if not when:
                        when = name_date(info.filename)
                        source = "name" if when else None
                    row.update(sha256=digest, width=w, height=hh, date_source=source,
                               taken=when.isoformat() if when else None)
                    if digest in seen:
                        row["status"] = "dup-in-zips"
                    elif in_library(by_dims, when, w, hh, kind == "video", aware):
                        row["status"] = "in-library"
                    else:
                        row["status"] = "new" if when else "new-undated"
                    seen.add(digest)
                counts[row["status"]] = counts.get(row["status"], 0) + 1
                out.write(json.dumps(row) + "\n")
        print(os.path.basename(z), counts, flush=True)
    out.close()
    print("total", counts)


if __name__ == "__main__":
    main()
