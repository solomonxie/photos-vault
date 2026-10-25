"""Local review page: name clusters, accept suggestions, drop wrong faces.
Serves on 127.0.0.1 only. Photos for context are read from the bucket on
demand and never written to disk."""

import io
import json
import os
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image, ImageDraw, ImageOps
from pillow_heif import register_heif_opener

import library
from store import CROPS, HERE, connect

register_heif_opener()


def state(db, lib):
    label = dict(db.execute("SELECT face_id, person FROM label WHERE source != 'cleared'"))
    check = defaultdict(list)
    for fid, person, sim in db.execute("SELECT * FROM suspect ORDER BY sim"):
        if label.get(fid) == person:
            check[person].append({"id": fid, "sim": round(sim, 2)})
    groups = defaultdict(list)
    for fid, c, person, sim in db.execute("SELECT * FROM cluster ORDER BY sim DESC"):
        if fid in label:
            continue
        groups[("suggest", person) if person else ("cluster", c)].append(
            {"id": fid, "sim": sim and round(sim, 2)})
    out = [{"kind": k, "key": str(v), "person": v if k == "suggest" else None, "faces": fs}
           for (k, v), fs in groups.items() if k == "suggest" or len(fs) >= 2]
    out += [{"kind": "check", "key": p, "person": p, "faces": fs} for p, fs in check.items()]
    out.sort(key=lambda g: ({"check": 0, "suggest": 1}.get(g["kind"], 2), -len(g["faces"])))
    people = defaultdict(list)
    for fid, person in label.items():
        if person:
            people[person].append(fid)
    names = sorted({p["name"] for p in lib["people"]} | set(people))
    return {"groups": out, "people": [{"name": n, "faces": fs} for n, fs in sorted(people.items())],
            "names": names}


def context_jpeg(db, lib, s3, bucket, face_id):
    key, x, y, w, h = db.execute(
        "SELECT key, x, y, w, h FROM face WHERE id = ?", (face_id,)).fetchone()
    thumb = next((((a.get("derivatives") or {}).get("thumbnail") or {}).get("destinationKey")
                  for a in lib["assets"]
                  if ((a.get("derivatives") or {}).get("original") or {}).get("destinationKey") == key),
                 None) or key
    body = s3.get_object(Bucket=bucket, Key=thumb)["Body"].read()
    im = ImageOps.exif_transpose(Image.open(io.BytesIO(body))).convert("RGB")
    im.thumbnail((1024, 1024))
    W, H = im.size
    ImageDraw.Draw(im).rectangle([x * W, y * H, (x + w) * W, (y + h) * H], outline="yellow", width=3)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=85)
    return buf.getvalue()


def serve(port):
    lib = library.snapshot()
    s3, bucket, _ = library.client()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, body, kind="application/json", code=200):
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            db = connect()
            p = self.path
            if p == "/":
                with open(os.path.join(HERE, "review.html"), "rb") as f:
                    self.send(f.read(), "text/html; charset=utf-8")
            elif p == "/api/state":
                self.send(json.dumps(state(db, lib)).encode())
            elif p.startswith("/crop/"):
                path = os.path.join(CROPS, os.path.basename(p))
                if os.path.exists(path):
                    with open(path, "rb") as f:
                        self.send(f.read(), "image/jpeg")
                else:
                    self.send(b"", code=404)
            elif p.startswith("/photo/"):
                try:
                    self.send(context_jpeg(db, lib, s3, bucket, int(p.split("/")[-1])), "image/jpeg")
                except Exception as e:  # noqa: BLE001 — shown in the overlay
                    self.send(str(e).encode(), "text/plain", 500)
            else:
                self.send(b"", code=404)

        def do_POST(self):
            db = connect()
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            ids = [int(i) for i in body["ids"]]
            if self.path == "/api/label":
                person = (body.get("person") or "").strip() or None
                db.executemany("INSERT OR REPLACE INTO label VALUES (?,?,'review')",
                               [(i, person) for i in ids])
            elif self.path == "/api/keep":
                db.executemany("UPDATE label SET source = 'kept' WHERE face_id = ?", [(i,) for i in ids])
            elif self.path == "/api/unlabel":
                db.executemany("INSERT OR REPLACE INTO label VALUES (?, NULL, 'cleared')",
                               [(i,) for i in ids])
            db.commit()
            self.send(b"{}")

    server = ThreadingHTTPServer(("127.0.0.1", port), H)
    print(f"http://127.0.0.1:{port}", flush=True)
    server.serve_forever()
