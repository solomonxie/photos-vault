"""Messenger / Instagram "Download your information" (JSON) -> rows. Zips, folders, or both."""

import json
import re
import zipfile
from collections import Counter
from datetime import datetime
from pathlib import Path

from rows import row

THREAD = re.compile(r"(?:^|/)messages/[^/]+/([^/]+)/message_\d+\.json$")


def fix(s):
    """Meta writes UTF-8 bytes as Latin-1 escapes: "ä½ å¥½" -> "你好"."""
    if not isinstance(s, str):
        return ""
    try:
        return s.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return s


def _files(paths):
    for path in paths:
        path = Path(path)
        if path.is_dir():
            for f in [*path.rglob("message_*.json"), *path.glob("*.json")]:
                yield f.as_posix(), f.read_bytes
        elif path.suffix == ".zip":
            z = zipfile.ZipFile(path)
            for n in z.namelist():
                if n.endswith(".json") and ("message_" in n or "/" not in n):
                    yield n, (lambda n=n, z=z: z.read(n))


def _media_index(paths):
    """Every non-JSON file in the exports, by full name and by base name."""
    index = {}
    for path in paths:
        path = Path(path)
        if path.suffix == ".zip":
            z = zipfile.ZipFile(path)
            for n in z.namelist():
                if not n.endswith((".json", "/")):
                    reader = (lambda n=n, z=z: z.read(n))
                    index[n] = (n, reader)
                    index.setdefault(Path(n).name, (n, reader))
        elif path.is_dir():
            for f in path.rglob("*"):
                if f.is_file() and f.suffix != ".json":
                    rel = f.relative_to(path).as_posix()
                    index[rel] = (rel, f.read_bytes)
                    index.setdefault(f.name, (rel, f.read_bytes))
    return index


def _media_of(m, index):
    for key in ("photos", "videos", "gifs", "media", "files"):
        for item in m.get(key) or []:
            uri = item.get("uri") if isinstance(item, dict) else item
            if not isinstance(uri, str):
                continue
            hit = index.get(uri) or index.get(Path(uri).name)
            if hit:
                name, read = hit
                return (name, read())
    return None


def _threads(paths):
    threads = {}
    for name, read in _files(paths):
        m = THREAD.search(name)
        if not m and ("/" in name.strip("/") or not name.endswith(".json")):
            continue
        data = json.loads(read())
        if not isinstance(data, dict) or "messages" not in data:
            continue
        # The encrypted-chats download is flat: <name>_<n>.json, its id in threadName.
        # Its _<n> suffix is a position in the download, not stable: dropped.
        thread = m.group(1) if m else re.sub(r"_\d+$", "", str(data.get("threadName") or Path(name).stem))
        t = threads.setdefault(thread, {"participants": set(), "messages": []})
        for p in data.get("participants", []):
            t["participants"].add(fix(p.get("name") if isinstance(p, dict) else p))
        t["messages"].extend(data.get("messages", []))
    return threads


def _kind(m):
    if m.get("photos") or m.get("videos") or m.get("gifs") or m.get("sticker"):
        return "image"
    if m.get("audio_files"):
        return "voice"
    if m.get("files"):
        return "file"
    if m.get("media"):
        return "image"
    return "text"


def extract(paths, source, me=None):
    threads = _threads(paths)
    index = _media_index(paths)
    if not me:
        counts = Counter(n for t in threads.values() for n in t["participants"])
        me = counts.most_common(1)[0][0] if counts else None
        print(f"you are taken to be {me!r}; pass --me if not")
    out, groups = [], 0
    for thread_id, t in threads.items():
        others = t["participants"] - {me}
        if len(others) != 1:
            groups += 1
            continue
        person = others.pop()
        seen = set()
        for m in t["messages"]:
            sender = fix(m.get("sender_name") or m.get("senderName"))
            ms = m.get("timestamp_ms") or m.get("timestamp")
            if not ms or m.get("is_unsent") or m.get("isUnsent"):
                continue
            text = fix(m.get("content") or m.get("text"))
            kind = _kind(m)
            if kind == "text" and not text:
                continue
            key = (ms, sender, text)
            if key in seen:
                continue  # same thread split over several zips
            seen.add(key)
            at = datetime.fromtimestamp(ms / 1000)
            media = _media_of(m, index) if kind in ("image", "file") else None
            out.append(row(person, source, f"{source}:{thread_id}", at, sender == me, text, kind, sender, media))
    if groups:
        print(f"skipped {groups} group chats")
    return out
