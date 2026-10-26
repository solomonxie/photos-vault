"""WhatsApp -> rows, from an iPhone backup (all chats) or per-chat "Export Chat" files."""

import re
import sqlite3
import zipfile
from datetime import datetime
from pathlib import Path

from rows import row

APPLE_EPOCH = 978307200
BACKUPS = Path.home() / "Library/Application Support/MobileSync/Backup"
DOMAIN = "AppDomainGroup-group.net.whatsapp.WhatsApp.shared"
# ZWAMESSAGE.ZMESSAGETYPE
TYPE_KIND = {0: "text", 1: "image", 2: "image", 3: "voice", 8: "file", 15: "image"}


def latest_backup():
    found = sorted(BACKUPS.glob("*/Manifest.db"), key=lambda p: p.stat().st_mtime)
    if not found:
        raise SystemExit(f"no iPhone backup under {BACKUPS}")
    return found[-1].parent


def _chat_storage(backup: Path):
    try:
        con = sqlite3.connect(f"file:{backup / 'Manifest.db'}?mode=ro", uri=True)
        hit = con.execute(
            "SELECT fileID FROM Files WHERE domain = ? AND relativePath = 'ChatStorage.sqlite'",
            (DOMAIN,),
        ).fetchone()
    except sqlite3.DatabaseError:
        raise SystemExit("Manifest.db unreadable: the backup is encrypted, back up again without encryption")
    if not hit:
        raise SystemExit("no WhatsApp in this backup")
    return backup / hit[0][:2] / hit[0]


def from_backup(backup: Path | None = None):
    db = _chat_storage(backup or latest_backup())
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    q = """
        SELECT s.ZCONTACTJID, s.ZPARTNERNAME, m.ZISFROMME, m.ZTEXT, m.ZMESSAGEDATE, m.ZMESSAGETYPE
        FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
        WHERE s.ZCONTACTJID LIKE '%@s.whatsapp.net' AND m.ZMESSAGEDATE IS NOT NULL
    """
    out = []
    for jid, partner, from_me, text, date, mtype in con.execute(q):
        kind = TYPE_KIND.get(mtype, "other")
        if kind == "text" and not (text or "").strip():
            continue
        number = jid.split("@")[0]
        person = (partner or "").strip() or f"+{number}"
        at = datetime.fromtimestamp(date + APPLE_EPOCH)
        out.append(row(person, "whatsapp", f"whatsapp:+{number}", at, from_me, text, kind))
    con.close()
    return out


# [25/10/2026, 08:24:13] Ava: hi        (iOS)
# 25/10/2026, 08:24 - Ava: hi           (Android)
LINE = re.compile(
    r"^\[?(\d{1,4})[./-](\d{1,2})[./-](\d{1,4}),?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp]\.?[Mm]\.?)?\]?\s*(?:-\s*)?(.*)$"
)
MEDIA = [
    (re.compile(r"(image|photo|video|gif|sticker) omitted|-PHOTO-|-VIDEO-|-STICKER-", re.I), "image"),
    (re.compile(r"audio omitted|-AUDIO-|\.opus", re.I), "voice"),
    (re.compile(r"document omitted|<attached:", re.I), "file"),
]


def _clean(s):
    return re.sub(r"[‎‏‪-‮]", "", s).replace(" ", " ").replace("\xa0", " ")


def _person_from_name(name):
    m = re.match(r"WhatsApp Chat (?:-|with) (.+?)(?:\.txt|\.zip)?$", name)
    return m.group(1).strip() if m else None


def _read_texts(path: Path):
    """[(person or None, text)] from a .txt, a .zip or a folder of them."""
    if path.is_dir():
        return [t for p in sorted(path.iterdir()) if p.suffix in (".txt", ".zip") for t in _read_texts(p)]
    if path.suffix == ".zip":
        with zipfile.ZipFile(path) as z:
            txt = next((n for n in z.namelist() if n.endswith(".txt")), None)
            if not txt:
                return []
            return [(_person_from_name(path.name), z.read(txt).decode("utf-8", "replace"))]
    return [(_person_from_name(path.name), path.read_text("utf-8", "replace"))]


def _day_first(heads):
    for a, b, _ in heads:
        if int(a) > 12:
            return True
        if int(b) > 12:
            return False
    return True


def _parse(text):
    # iOS marks system notices ("Messages and calls are end-to-end encrypted") with a
    # leading U+200E after the colon; media lines too, which MEDIA still catches.
    lines = [_clean(line.replace(": \u200e", ": \0")) for line in text.splitlines()]
    msgs, heads = [], []
    for line in lines:
        m = LINE.match(line)
        if m:
            heads.append(m.groups()[:3])
            msgs.append([m.groups(), m.group(8)])
        elif msgs:
            msgs[-1][1] += "\n" + line
    day_first = _day_first(heads)
    out = []
    for g, body in msgs:
        a, b, c, hh, mm, ss, ampm, _ = g
        if len(a) == 4:
            y, mo, d = int(a), int(b), int(c)
        else:
            y = int(c) + (2000 if len(c) == 2 else 0)
            d, mo = (int(a), int(b)) if day_first else (int(b), int(a))
        h = int(hh)
        if ampm:
            pm = ampm[0].lower() == "p"
            h = h % 12 + (12 if pm else 0)
        at = datetime(y, mo, d, h, int(mm), int(ss or 0))
        if ": " not in body:
            continue  # system line: no sender
        sender, said = body.split(": ", 1)
        out.append((at, sender.strip(), said.strip(" \n")))
    return out


def from_exports(path: Path, me: str | None):
    out = []
    for person, text in _read_texts(path):
        msgs = _parse(text)
        if not msgs:
            continue  # only system notices, e.g. disappearing messages
        senders = {s for _, s, _ in msgs}
        if len(senders) > 2:
            print(f"skipped group chat: {person}")
            continue
        if me:
            others = senders - {me}
        elif "You" in senders:  # WhatsApp Web's export names the owner "You"
            others = (senders - {"You"}) or ({person} if person else set())
        else:
            others = {person} & senders
        if len(others) != 1:
            print(f"skipped {person or 'a chat'}: can't tell who is who, pass --me")
            continue
        them = others.pop()
        person = person or them
        for at, sender, said in msgs:
            kind = next((k for rx, k in MEDIA if rx.search(said)), "text")
            if said.startswith("\0"):
                if kind == "text":
                    continue
                said = said[1:]
            from_me = sender != them
            out.append(row(person, "whatsapp", f"whatsapp:{person}", at, from_me,
                           "" if kind != "text" else said, kind, sender))
    return out
