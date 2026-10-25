"""Download originals in small batches, find and embed faces, delete the file.
At most WINDOW originals are on disk at once."""

import os
import shutil
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np
from PIL import Image, ImageOps
from pillow_heif import register_heif_opener

import library
from recognizer import Recognizer
from store import CROPS, WORK, connect, to_blob

register_heif_opener()
MAX_SIDE = 2048
WINDOW = 16


def decode(path):
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert("RGB")
        im.thumbnail((MAX_SIDE, MAX_SIDE))
        return cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)


def crop(bgr, box, side=160, pad=0.35):
    x1, y1, x2, y2 = box
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    r = max(x2 - x1, y2 - y1) * (0.5 + pad)
    h, w = bgr.shape[:2]
    a, b = int(max(0, cx - r)), int(max(0, cy - r))
    c, d = int(min(w, cx + r)), int(min(h, cy + r))
    return cv2.resize(bgr[b:d, a:c], (side, side))


def analyse_one(rec, path):
    bgr = decode(path)
    h, w = bgr.shape[:2]
    faces = []
    for box, kps, score in rec.detect(bgr):
        x1, y1, x2, y2 = np.clip(box, 0, [w, h, w, h])
        if x2 - x1 < 8 or y2 - y1 < 8:
            continue
        vec, aligned = rec.embed(bgr, kps)
        eye_l, eye_r, nose = kps[0], kps[1], kps[2]
        yaw = float((nose[0] - eye_l[0]) / max(eye_r[0] - eye_l[0], 1e-3))
        blur = cv2.Laplacian(cv2.cvtColor(aligned, cv2.COLOR_BGR2GRAY), cv2.CV_64F).var()
        faces.append(dict(
            x=x1 / w, y=y1 / h, w=(x2 - x1) / w, h=(y2 - y1) / h, score=score,
            size=float(min(x2 - x1, y2 - y1)), blur=float(blur), yaw=yaw, vec=vec,
            thumb=crop(bgr, (x1, y1, x2, y2))))
    return w, h, faces


def run(limit=None):
    db = connect()
    lib = library.snapshot()
    done = {k for (k,) in db.execute("SELECT key FROM photo")}
    todo = [(lid, key) for lid, key in library.open_photos(lib) if key not in done]
    labelled = library.manual_labels(lib)
    todo.sort(key=lambda t: t[0] not in labelled)  # seeds first: results show early
    if limit:
        todo = todo[:limit]
    print(f"{len(done)} done, {len(todo)} to analyse")
    if not todo:
        return
    s3, bucket, _ = library.client()
    rec = Recognizer()
    tmp = tempfile.mkdtemp(dir=WORK, prefix="dl-")

    def fetch(item):
        lid, key = item
        path = os.path.join(tmp, os.path.basename(key))
        try:
            s3.download_file(bucket, key, path)
            return lid, key, path, None
        except Exception as e:  # noqa: BLE001 — recorded per photo, run goes on
            return lid, key, None, str(e)

    started, n_faces = time.time(), 0
    try:
        with ThreadPoolExecutor(4) as pool:
            for i in range(0, len(todo), WINDOW):
                for lid, key, path, err in pool.map(fetch, todo[i:i + WINDOW]):
                    w = h = None
                    if path:
                        try:
                            w, h, faces = analyse_one(rec, path)
                        except Exception as e:  # noqa: BLE001
                            err, faces = str(e), []
                        finally:
                            os.remove(path)
                        for f in faces:
                            cur = db.execute(
                                "INSERT INTO face (key,x,y,w,h,score,size,blur,yaw,vec) "
                                "VALUES (?,?,?,?,?,?,?,?,?,?)",
                                (key, f["x"], f["y"], f["w"], f["h"], f["score"],
                                 f["size"], f["blur"], f["yaw"], to_blob(f["vec"])))
                            cv2.imwrite(os.path.join(CROPS, f"{cur.lastrowid}.jpg"),
                                        f["thumb"], [cv2.IMWRITE_JPEG_QUALITY, 85])
                        n_faces += len(faces)
                    db.execute("INSERT OR REPLACE INTO photo VALUES (?,?,?,?,?,?,?)",
                               (key, lid, None, w, h, err, int(time.time())))
                    db.commit()
                n = min(i + WINDOW, len(todo))
                rate = n / (time.time() - started)
                print(f"{n}/{len(todo)} photos, {n_faces} faces, {rate:.1f}/s", flush=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
