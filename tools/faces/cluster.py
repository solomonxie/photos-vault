"""Seeds from the app's photo-level labels, suggestions against named people,
then clusters of what's left. Labels made in review are never touched."""

from collections import defaultdict

import numpy as np
from sklearn.cluster import AgglomerativeClustering

import library
from store import connect, from_blob

MATCH = 0.42      # kNN similarity to call a face someone's
MARGIN = 0.06     # over the runner-up person
GROUP = 0.45      # average-linkage similarity inside a cluster
ATTACH = 0.50     # a weak face joining a group's centre
ATTACH_CORE = 3   # good faces a group needs before weak ones may join
MIN_SIZE = 40     # px, shorter side
MIN_SCORE = 0.6
FRONTAL = (0.2, 0.8)  # nose between the eyes, as a fraction of their gap


def good(f):
    return (f["size"] >= MIN_SIZE and f["score"] >= MIN_SCORE
            and FRONTAL[0] <= f["yaw"] <= FRONTAL[1])


def load(db):
    rows = db.execute(
        "SELECT f.id, f.key, f.size, f.score, f.vec, p.local_id, f.yaw "
        "FROM face f JOIN photo p ON p.key = f.key").fetchall()
    faces = [dict(id=r[0], key=r[1], size=r[2], score=r[3], local_id=r[5], yaw=r[6]) for r in rows]
    vecs = np.stack([from_blob(r[4]) for r in rows]) if rows else np.zeros((0, 512), np.float32)
    return faces, vecs


def seeds(faces, vecs, labels):
    """Photo-level labels -> one face per labelled photo: the face most like
    that person's faces in their other photos (the largest if alone)."""
    by_photo = defaultdict(list)
    for i, f in enumerate(faces):
        by_photo[f["local_id"]].append(i)
    photos_of = defaultdict(list)
    for lid, names in labels.items():
        for n in names:
            if by_photo.get(lid):
                photos_of[n].append(lid)
    out = {}
    for name, lids in photos_of.items():
        for lid in lids:
            cand = by_photo[lid]
            others = [j for o in lids if o != lid for j in by_photo[o]]
            if not others:
                best = max(cand, key=lambda i: faces[i]["size"])
            else:
                sims = vecs[cand] @ vecs[others].T
                # per other photo, its best match; averaged
                score = []
                for row in sims:
                    per, k = [], 0
                    for o in lids:
                        if o == lid:
                            continue
                        n = len(by_photo[o])
                        per.append(row[k:k + n].max())
                        k += n
                    score.append(np.mean(per))
                if max(score) < 0.25 and len(cand) > 1:
                    continue
                best = cand[int(np.argmax(score))]
            out.setdefault(faces[best]["id"], name)
    return out


def main_group(rows, vecs, link=GROUP):
    """The person's main group: the largest set of their faces linked by
    similarity. A wrong label outside it is dropped however many friends it
    has; with fewer than 3 faces there's no majority, so all are kept."""
    if len(rows) < 3:
        return set(rows)
    sims = vecs[rows] @ vecs[rows].T
    parent = list(range(len(rows)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for a, b in zip(*np.where(np.triu(sims >= link, 1))):
        parent[find(a)] = find(b)
    comps = defaultdict(list)
    for a in range(len(rows)):
        comps[find(a)].append(rows[a])
    return set(max(comps.values(), key=len))


def run():
    db = connect()
    faces, vecs = load(db)
    if not faces:
        print("no faces yet: run analyse")
        return
    lib = library.snapshot()
    seeded = seeds(faces, vecs, library.manual_labels(lib))
    db.execute("DELETE FROM label WHERE source = 'app'")
    reviewed = {fid for (fid,) in db.execute("SELECT face_id FROM label")}
    db.executemany("INSERT INTO label VALUES (?,?,'app')",
                   [(fid, n) for fid, n in seeded.items() if fid not in reviewed])
    # 'cleared': a seed you removed; open again, never re-seeded
    label = dict(db.execute("SELECT face_id, person FROM label WHERE source != 'cleared'"))
    kept = {fid for (fid,) in db.execute("SELECT face_id FROM label WHERE source = 'kept'")}

    idx = {f["id"]: i for i, f in enumerate(faces)}
    named, suspects = {}, []
    by_person = defaultdict(list)
    for fid, person in label.items():
        if person and fid in idx:
            by_person[person].append(idx[fid])
    for person, rows in by_person.items():
        main = main_group(rows, vecs) | {idx[f] for f in kept if f in idx and label[f] == person}
        named[person] = sorted(main)
        if len(main) >= 2:
            centre = vecs[sorted(main)].mean(axis=0)
            centre /= np.linalg.norm(centre)
            suspects += [(faces[i]["id"], person, float(vecs[i] @ centre))
                         for i in rows if i not in main]

    open_ = [i for i, f in enumerate(faces) if f["id"] not in label]
    suggested = {}
    if named and open_:
        people = sorted(named)
        knn = np.stack([
            np.sort(vecs[open_] @ vecs[named[p]].T, axis=1)[:, ::-1][:, :3].mean(axis=1)
            for p in people], axis=1)
        order = np.argsort(-knn, axis=1)
        for r, i in enumerate(open_):
            best = knn[r, order[r, 0]]
            second = knn[r, order[r, 1]] if len(people) > 1 else 0
            if best >= MATCH and best - second >= MARGIN:
                suggested[i] = (people[order[r, 0]], float(best))

    rest = [i for i in open_ if i not in suggested]
    core = [i for i in rest if good(faces[i])]
    cluster = {}
    if len(core) >= 2:
        ids = AgglomerativeClustering(
            n_clusters=None, metric="cosine", linkage="average",
            distance_threshold=1 - GROUP).fit_predict(vecs[core])
        cluster = dict(zip(core, ids.tolist()))
        # cannot-link: one face per photo per cluster, the most central stays
        members = defaultdict(list)
        for i, c in cluster.items():
            members[c].append(i)
        for c, ms in members.items():
            if len(ms) < 2:
                continue
            centre = vecs[ms].mean(axis=0)
            seen = set()
            for i in sorted(ms, key=lambda i: -float(vecs[i] @ centre)):
                if faces[i]["local_id"] in seen:
                    del cluster[i]
                seen.add(faces[i]["local_id"])
        # weak faces join the nearest cluster centre, if close enough
        members = defaultdict(list)
        for i, c in cluster.items():
            members[c].append(i)
        # junk faces look alike and pile onto any small group: only solid ones take them
        big = [c for c, ms in members.items() if len(ms) >= ATTACH_CORE]
        if big:
            centres = np.stack([vecs[members[c]].mean(axis=0) for c in big])
            centres /= np.linalg.norm(centres, axis=1, keepdims=True)
            for i in rest:
                if i in cluster:
                    continue
                sims = centres @ vecs[i]
                j = int(np.argmax(sims))
                if sims[j] >= ATTACH:
                    cluster[i] = big[j]

    db.execute("DELETE FROM suspect")
    db.executemany("INSERT INTO suspect VALUES (?,?,?)", suspects)
    db.execute("DELETE FROM cluster")
    db.executemany("INSERT INTO cluster VALUES (?,?,?,?)", [
        (faces[i]["id"], None, p, s) for i, (p, s) in suggested.items()] + [
        (faces[i]["id"], c, None, None) for i, c in cluster.items()])
    db.commit()
    sizes = defaultdict(int)
    for c in cluster.values():
        sizes[c] += 1
    print(f"suspect labels: {len(suspects)}")
    print(f"{len(faces)} faces; seeds {len(seeded)} for {len(set(seeded.values()))} people; "
          f"suggested {len(suggested)}; clusters ≥2: {sum(1 for s in sizes.values() if s >= 2)} "
          f"({sum(s for s in sizes.values() if s >= 2)} faces); left alone {len(open_) - len(suggested) - sum(s for s in sizes.values() if s >= 2)}")
