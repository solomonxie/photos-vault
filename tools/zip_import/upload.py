"""Sends what survey.py found new to the bucket the way the phone backs up:
stills as HEIF (`.heif` marks a converted upload), GIFs and videos as they
are, each with a 512 px JPEG thumbnail. The name carries the date taken —
`import_<YYYYMMDDHHMMSS>_<12 hex>` — which the app's Import from Bucket
falls back to when it can't read one from the file. Each goes straight to
the app's own name (`<stamp>_<sha256(import key)[:32]>`), logged to
uploaded.jsonl and renamed.jsonl; a key already in the bucket is never
written over, and nothing is deleted. Nothing without a date
is sent: those wait in survey.jsonl for one (see dates.jsonl).

Usage: upload.py  (WORK=/tmp/zip-import, .env.bucket at the repo root)"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import boto3

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.environ.get("WORK", "/tmp/zip-import")


def client():
    env = {}
    for line in open(os.path.join(ROOT, ".env.bucket")):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k] = v.strip().strip("'\"")
    return boto3.client(
        "s3",
        aws_access_key_id=env["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=env["AWS_SECRET_ACCESS_KEY"],
        region_name=env.get("AWS_DEFAULT_REGION"),
    ), env["BUCKET"], env["PREFIX"]


def stamp(row, dates):
    when = dates.get(row["sha256"]) or row.get("taken")
    if not when:
        return None
    t = datetime.fromisoformat(when)
    if t.tzinfo is not None:  # a video's UTC creation time: shown as local
        t = t.astimezone().replace(tzinfo=None)
    return t.strftime("%Y%m%d%H%M%S")


def run(cmd):
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"{cmd[0]}: {r.stderr.decode()[:200]}")


def prepare(row, tmp, when):
    ext = row["name"].rsplit(".", 1)[-1].lower()
    base = f"import_{when}_{row['sha256'][:12]}"
    src = os.path.join(tmp, "src." + ext)
    with zipfile.ZipFile(row["zip"]) as zf, zf.open(row["name"]) as f, open(src, "wb") as out:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            out.write(chunk)
    thumb = os.path.join(tmp, base + ".jpg")
    if row["kind"] == "video":
        original, out_ext = src, ext
        try:
            run(["ffmpeg", "-v", "error", "-y", "-ss", "1", "-i", src, "-frames:v", "1",
                 "-vf", "scale='min(512,iw)':-2", "-q:v", "4", thumb])
        except RuntimeError:
            pass
        # Shorter than a second: no frame at 1 s, and no error either.
        if not os.path.exists(thumb):
            run(["ffmpeg", "-v", "error", "-y", "-i", src, "-frames:v", "1",
                 "-vf", "scale='min(512,iw)':-2", "-q:v", "4", thumb])
    elif ext == "gif":
        original, out_ext = src, ext
        run(["sips", "-s", "format", "jpeg", "-Z", "512", src, "--out", thumb])
    else:
        original, out_ext = os.path.join(tmp, base + ".heif"), "heif"
        run(["sips", "-s", "format", "heic", "-s", "formatOptions", "82", src, "--out", original])
        run(["sips", "-s", "format", "jpeg", "-Z", "512", src, "--out", thumb])
    return base, original, out_ext, thumb


def main():
    s3, bucket, prefix = client()
    rows = [json.loads(l) for l in open(os.path.join(WORK, "survey.jsonl"))]
    dates_path = os.path.join(WORK, "dates.jsonl")
    dates = {}
    if os.path.exists(dates_path):
        for l in open(dates_path):
            d = json.loads(l)
            dates[d["sha256"]] = d["taken"]
    done_path = os.path.join(WORK, "uploaded.jsonl")
    done = set()
    if os.path.exists(done_path):
        done = {json.loads(l)["sha256"] for l in open(done_path)}
    todo = [r for r in rows if r["status"] in ("new", "new-undated")
            and r["sha256"] not in done and stamp(r, dates)]
    limit = int(os.environ.get("LIMIT", "0"))
    if limit:
        todo = todo[:limit]
    print(f"to send: {len(todo)}", flush=True)

    def exists(key):
        try:
            s3.head_object(Bucket=bucket, Key=key)
            return True
        except s3.exceptions.ClientError as e:
            if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
                return False
            raise

    def send(row):
        with tempfile.TemporaryDirectory(prefix="zip-import-") as tmp:
            base, original, ext, thumb = prepare(row, tmp, stamp(row, dates))
            old = f"{prefix}/originals/{base}.{ext}"
            # The app's own name, as rename.py used to give it: adds only, no deletes.
            final = f"{base.split('_')[1]}_{hashlib.sha256(old.encode()).hexdigest()[:32]}"
            key = f"{prefix}/originals/{final}.{ext}"
            thumb_key = f"{prefix}/thumbnails/{final}.jpg"
            if exists(key) or exists(thumb_key):
                raise RuntimeError(f"exists, skipped: {key}")
            s3.upload_file(original, bucket, key)
            if s3.head_object(Bucket=bucket, Key=key)["ContentLength"] != os.path.getsize(original):
                raise RuntimeError(f"size mismatch {key}")
            s3.upload_file(thumb, bucket, thumb_key, ExtraArgs={"ContentType": "image/jpeg"})
            return ({"sha256": row["sha256"], "key": old, "name": row["name"]},
                    {"from": old, "to": key, "sha256": row["sha256"]})

    n = failed = 0
    with ThreadPoolExecutor(6) as ex, open(done_path, "a") as log, \
            open(os.path.join(WORK, "renamed.jsonl"), "a") as renamed:
        futures = [ex.submit(send, r) for r in todo]
        for f in futures:
            try:
                up, rn = f.result()
                log.write(json.dumps(up) + "\n")
                log.flush()
                renamed.write(json.dumps(rn) + "\n")
                renamed.flush()
                n += 1
            except Exception as e:
                failed += 1
                print("failed:", str(e)[:160], flush=True)
            if (n + failed) % 200 == 0:
                print(f"sent {n}, failed {failed}", flush=True)
    print(f"sent {n}, failed {failed}")


if __name__ == "__main__":
    sys.exit(main())
