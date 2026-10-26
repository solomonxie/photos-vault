"""The app's chat import line: lib/photos/conversation_file.dart."""

import base64
import hashlib
import json
import shutil
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

KINDS = {"text", "image", "voice", "file", "system", "other"}
THUMB_PX = 240
VIDEO = {".mov", ".mp4", ".m4v", ".3gp", ".avi", ".webm"}
PICTURE = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".tif", ".tiff", ".bmp", ".ktx"}


def row(person, source, chat, at: datetime, from_me, text, kind="text", sender=None, media=None):
    """media: the picture, video or file it carried (a path, or (name, bytes)); becomes `thumb` on write."""
    assert kind in KINDS, kind
    r = {
        "person": person,
        "source": source,
        "chat": chat,
        "at": at.replace(tzinfo=None, microsecond=0).isoformat(),
        "from_me": bool(from_me),
        "sender": sender or ("Me" if from_me else person),
        "text": text or "",
        "kind": kind,
    }
    if media is not None:
        r["_media"] = media
    return r


def _run(cmd):
    try:
        subprocess.run(cmd, capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        pass


def thumbnail(src: Path, scratch: Path) -> bytes | None:
    """A ~240px low-quality JPEG: pictures shrunk, a video's opening frame, a file's Quick Look preview."""
    out = scratch / f"{hashlib.sha1(str(src).encode()).hexdigest()[:12]}.jpg"
    ext = src.suffix.lower()
    if ext in VIDEO:
        _run(["ffmpeg", "-loglevel", "error", "-y", "-ss", "0.5", "-i", str(src), "-frames:v", "1",
              "-vf", f"scale={THUMB_PX}:-2", "-q:v", "14", str(out)])
    else:
        picture = src
        if ext not in PICTURE:
            _run(["qlmanage", "-t", "-s", str(THUMB_PX), "-o", str(scratch), str(src)])
            picture = scratch / f"{src.name}.png"
            if not picture.exists():
                return None
        _run(["sips", "-Z", str(THUMB_PX), "-s", "format", "jpeg", "-s", "formatOptions", "35",
              str(picture), "--out", str(out)])
    return out.read_bytes() if out.exists() and out.stat().st_size else None


def _materialise(media, scratch: Path) -> Path | None:
    if isinstance(media, Path):
        return media if media.exists() else None
    name, data = media
    p = scratch / f"{hashlib.sha1(data).hexdigest()[:12]}{Path(name).suffix}"
    p.write_bytes(data)
    return p


def write(rows, out: Path):
    rows = sorted(rows, key=lambda r: (r["chat"], r["at"]))
    out = out.with_suffix(".jsonl")
    out.parent.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(dir=out.parent, prefix=".thumbs-"))
    made = {}
    try:
        for r in rows:
            media = r.pop("_media", None)
            if media is None:
                continue
            key = str(media) if isinstance(media, Path) else media[0] + hashlib.sha1(media[1]).hexdigest()
            if key not in made:
                src = _materialise(media, scratch)
                made[key] = thumbnail(src, scratch) if src else None
            if made[key]:
                r["thumb"] = base64.b64encode(made[key]).decode()
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), "utf-8")
    thumbs = sum(1 for r in rows if "thumb" in r)
    people = {r["person"] for r in rows}
    print(f"{out}: {len(rows)} messages, {len(people)} people, {thumbs} thumbnails, {out.stat().st_size / 1e6:.1f} MB")
