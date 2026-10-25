"""Names already given on the phone, as labels: a copy of the app's
`ai_analysis.db` and `people.db` (read only), each named face matched to
the face found here in the same photo."""

import sqlite3
from collections import defaultdict

from store import connect


def _box(s):
    x, y, w, h = (float(v) for v in s.split(","))
    return x, y, w, h


def _agree(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0, min(ay + ah, by + bh) - max(ay, by))
    inter = ix * iy
    iou = inter / (aw * ah + bw * bh - inter) if inter else 0
    cx, cy = ax + aw / 2, ay + ah / 2
    return iou if iou >= 0.3 or (bx <= cx <= bx + bw and by <= cy <= by + bh) else None


def run(analysis_db, people_db):
    phone = sqlite3.connect(f"file:{analysis_db}?mode=ro", uri=True)
    names = dict(sqlite3.connect(f"file:{people_db}?mode=ro", uri=True)
                 .execute("SELECT id, name FROM person"))
    named = defaultdict(list)
    for lid, face, pid in phone.execute(
            "SELECT local_id, face, person_id FROM face_descriptor WHERE person_id IS NOT NULL"):
        if pid in names:
            named[lid].append((_box(face), names[pid]))

    db = connect()
    here = defaultdict(list)
    for fid, lid, x, y, w, h in db.execute(
            "SELECT f.id, p.local_id, f.x, f.y, f.w, f.h FROM face f JOIN photo p ON p.key = f.key"):
        if lid in named:
            here[lid].append((fid, (x, y, w, h)))
    mine = {fid for (fid,) in db.execute(
        "SELECT face_id FROM label WHERE source IN ('review', 'kept', 'cleared')")}

    labels = {}
    for lid, faces in named.items():
        pairs = sorted(((s, fid, name) for box, name in faces for fid, b in here[lid]
                        if (s := _agree(box, b)) is not None), reverse=True)
        taken = set()
        for _, fid, name in pairs:
            if fid in taken or name in {labels.get(t) for t in taken}:
                continue
            taken.add(fid)
            labels[fid] = name
    db.execute("DELETE FROM label WHERE source = 'phone'")
    db.execute("DELETE FROM label WHERE source = 'app' AND face_id IN (%s)" % ",".join("?" * len(labels)),
               list(labels))
    db.executemany("INSERT OR IGNORE INTO label VALUES (?,?,'phone')",
                   [(fid, n) for fid, n in labels.items() if fid not in mine])
    db.commit()
    print(f"{sum(map(len, named.values()))} named on the phone; {len(labels)} matched here "
          f"for {len(set(labels.values()))} people")
