"""~/Library/Messages/chat.db -> rows. One-to-one chats only."""

import sqlite3
from datetime import datetime
from pathlib import Path

from contacts import Contacts
from rows import row

DB = Path.home() / "Library/Messages/chat.db"
APPLE_EPOCH = 978307200
ONE_TO_ONE = 45


def _seconds(apple_date):
    # Nanoseconds since 2001 since High Sierra; seconds before.
    return apple_date / 1e9 if apple_date > 1e11 else apple_date


def body_text(blob):
    """Text out of attributedBody (typedstream): newer messages leave `text` NULL."""
    if not blob:
        return ""
    i = blob.find(b"NSString")
    if i < 0:
        return ""
    i = blob.find(b"+", i + 8)
    if i < 0:
        return ""
    i += 1
    n = blob[i]
    i += 1
    if n == 0x81:
        n = int.from_bytes(blob[i : i + 2], "little")
        i += 2
    elif n == 0x82:
        n = int.from_bytes(blob[i : i + 4], "little")
        i += 4
    return blob[i : i + n].decode("utf-8", "replace")


def _kind(mimes):
    if not mimes:
        return "text"
    m = mimes[0] or ""
    if m.startswith("image/") or m.startswith("video/"):
        return "image"
    if m.startswith("audio/"):
        return "voice"
    return "file"


PREVIEWS = Path.home() / "Library/Messages/Caches/Previews/Attachments"
ATTACHMENTS = Path.home() / "Library/Messages/Attachments"


def _on_disk(path: Path):
    """The picture itself, or the small preview Messages keeps when the original is only in iCloud."""
    if path.exists():
        return path
    try:
        folder = PREVIEWS / path.parent.relative_to(ATTACHMENTS)
    except ValueError:
        return None
    hits = sorted(folder.glob(f"{path.stem}-preview*")) if folder.exists() else []
    if not hits:
        hits = sorted(PREVIEWS.glob(f"*/*/*/{path.stem}-preview*"))
    return hits[0] if hits else None


def extract(db=DB):
    contacts = Contacts()
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        con.execute("SELECT 1 FROM message LIMIT 1")
    except sqlite3.OperationalError:
        raise SystemExit("can't read chat.db: give this terminal Full Disk Access, then restart it")
    mimes, files = {}, {}
    for mid, mime, filename in con.execute(
        "SELECT j.message_id, a.mime_type, a.filename FROM message_attachment_join j"
        " JOIN attachment a ON a.ROWID = j.attachment_id"
    ):
        mimes.setdefault(mid, []).append(mime)
        if filename and not (mime or "").startswith("audio/"):
            if found := _on_disk(Path(filename).expanduser()):
                files.setdefault(mid, found)
    q = """
        SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me, m.service,
               c.chat_identifier
        FROM message m
        JOIN chat_message_join cm ON cm.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cm.chat_id
        WHERE c.style = ? AND m.associated_message_type = 0 AND m.item_type = 0
    """
    out, unnamed = [], set()
    for mid, text, body, date, from_me, service, handle in con.execute(q, (ONE_TO_ONE,)):
        text = (text or body_text(body)).replace("￼", "").strip()
        kind = _kind(mimes.get(mid))
        if not text and kind == "text":
            continue
        person = contacts.name(handle)
        if not person:
            unnamed.add(handle)
            person = handle
        source = "imessage" if service == "iMessage" else "sms"
        at = datetime.fromtimestamp(_seconds(date) + APPLE_EPOCH)
        out.append(row(person, source, f"{source}:{handle}", at, from_me, text, kind, media=files.get(mid)))
    con.close()
    if unnamed:
        print(f"{len(unnamed)} handles not in Contacts, kept as the number/email")
    return out
