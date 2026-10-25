"""faces.json v2: named faces keep their name, every grouped face carries a
group ID, groups that look like a named person carry `suggest`. Naming
happens in the app (People → Faces to Name)."""

import json
import time
from collections import defaultdict

from library import stem
from store import connect


def _same_ids(prev, members, boxes):
    """A group mostly made of one earlier group's faces keeps its ID, so the
    app adds to the group it has instead of opening a second one."""
    if not prev:
        return {}
    with open(prev, encoding="utf-8") as f:
        doc = json.load(f)
    before = {(p["key"], tuple(f["box"])): f["group"]
              for p in doc["photos"] for f in p["faces"] if "group" in f}
    size = defaultdict(int)
    for old in before.values():
        size[old] += 1
    votes = []
    for g, fids in members.items():
        n = defaultdict(int)
        for fid in fids:
            if (old := before.get(boxes.get(fid))) is not None:
                n[old] += 1
        for old, k in n.items():
            if k * 2 >= len(fids) or k * 2 >= size[old]:
                votes.append((k, g, old))
    keep, used = {}, set()
    for k, g, old in sorted(votes, reverse=True):
        if g not in keep and old not in used:
            keep[g] = old
            used.add(old)
    return keep


def run(out, prev=None):
    db = connect()
    run_id = "r" + time.strftime("%Y%m%d%H%M")
    suspects = {fid for (fid,) in db.execute("SELECT face_id FROM suspect")}
    named = {fid: p for fid, p in db.execute(
        "SELECT face_id, person FROM label WHERE person IS NOT NULL AND source != 'cleared'")
        if fid not in suspects}
    done = {fid for (fid,) in db.execute("SELECT face_id FROM label WHERE source != 'cleared'")}

    members = defaultdict(list)
    for fid, c, suggest in db.execute("SELECT face_id, cluster, suggested FROM cluster"):
        if fid not in done:
            members[("s", suggest) if suggest else ("c", c)].append(fid)
    boxes = {fid: (stem(key), tuple(round(v, 4) for v in box)) for fid, key, *box in
             db.execute("SELECT id, key, x, y, w, h FROM face")}
    keep = _same_ids(prev, members, boxes)
    groups, group_of = [], {}
    ordered = sorted(members.items(), key=lambda kv: (kv[0][0] != "s", -len(kv[1])))
    for n, ((kind, v), fids) in enumerate(ordered, 1):
        if kind == "c" and len(fids) < 2:
            continue
        gid = keep.get((kind, v)) or f"{run_id}-{n:04d}"
        groups.append({"id": gid, "faces": len(fids), **({"suggest": v} if kind == "s" else {})})
        group_of.update({f: gid for f in fids})

    photos = defaultdict(list)
    for fid, key, x, y, w, h in db.execute("SELECT id, key, x, y, w, h FROM face ORDER BY key"):
        box = [round(v, 4) for v in (x, y, w, h)]
        if fid in named:
            photos[key].append({"box": box, "person": named[fid]})
        elif fid in group_of:
            photos[key].append({"box": box, "group": group_of[fid]})
    doc = {"version": 2, "groups": groups,
           "photos": [{"key": stem(k), "faces": fs} for k, fs in photos.items()]}
    with open(out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False)
    print(f"{out}: {len(named)} named faces, {len(group_of)} grouped in {len(groups)} groups "
          f"({sum(1 for g in groups if 'suggest' in g)} suggested), {len(photos)} photos")
