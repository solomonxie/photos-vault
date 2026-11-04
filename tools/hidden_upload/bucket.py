"""Bucket side of the Mac hidden upload: `prep` fetches index.bin and a pool
of decoys (ordinary photos' sizes and thumbnails); `upload` sends built
carriers and lists what landed for the phone to adopt."""

import json
import os
import random
import sqlite3
import sys
from concurrent.futures import ThreadPoolExecutor

import boto3

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.environ["PV_WORK"]


def client():
    env = {}
    with open(os.path.join(ROOT, ".env.bucket")) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v.strip().strip("'\"")
    s3 = boto3.client(
        "s3",
        aws_access_key_id=env["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=env["AWS_SECRET_ACCESS_KEY"],
        region_name=env.get("AWS_DEFAULT_REGION"),
    )
    return s3, env["BUCKET"], env["PREFIX"]


def prep(pool=100000):
    s3, bucket, prefix = client()
    s3.download_file(bucket, f"{prefix}/app-data/index.bin", os.path.join(WORK, "index.bin"))
    sizes = {}
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=f"{prefix}/originals/"):
        for o in page.get("Contents", []):
            sizes[o["Key"]] = o["Size"]
    db = sqlite3.connect(f"file:{os.path.join(WORK, 'photos_vault.db')}?mode=ro", uri=True)
    rows = db.execute(
        "SELECT local_id, original_key, thumbnail_key, width, height, created_at FROM asset_record "
        "WHERE passcode_hash IS NULL AND deleted_at IS NULL AND is_video = 0 "
        "AND original_status = 'uploaded' AND thumbnail_status = 'uploaded' "
        "AND width > 0 AND height > 0").fetchall()
    rows = [r for r in rows if r[1] in sizes and r[2]]
    random.shuffle(rows)
    thumbs = os.path.join(WORK, "thumbs")
    os.makedirs(thumbs, exist_ok=True)

    def fetch(r):
        local_id, original, thumb, w, h, taken = r
        path = os.path.join(thumbs, os.path.basename(thumb))
        if not os.path.exists(path):
            s3.download_file(bucket, thumb, path)
        return {"id": local_id, "size": sizes[original], "width": w, "height": h,
                "taken": taken, "thumb": path}

    with ThreadPoolExecutor(8) as ex:
        decoys = list(ex.map(fetch, rows[:pool]))
    with open(os.path.join(WORK, "decoys.json"), "w") as f:
        json.dump(decoys, f)
    print(f"index.bin, {len(decoys)} decoys of {len(rows)}")


def upload():
    s3, bucket, prefix = client()
    out = os.path.join(WORK, "out")
    done_path = os.path.join(WORK, "uploaded.jsonl")
    done = set()
    if os.path.exists(done_path):
        done = {json.loads(l)["localId"] for l in open(done_path)}
    built = [json.loads(l) for l in open(os.path.join(WORK, "built.jsonl"))]
    todo = [b for b in built if b["localId"] not in done and os.path.exists(os.path.join(out, b["file"]))]

    def send(b):
        path = os.path.join(out, b["file"])
        key = f"{prefix}/originals/{b['file']}"
        size = os.path.getsize(path)
        s3.upload_file(path, bucket, key, ExtraArgs={"ContentType": "image/jpeg"})
        if s3.head_object(Bucket=bucket, Key=key)["ContentLength"] != size:
            raise RuntimeError(f"size mismatch {key}")
        os.remove(path)
        return b

    n = 0
    with ThreadPoolExecutor(16) as ex, open(done_path, "a") as f:
        for b in ex.map(send, todo):
            f.write(json.dumps({"localId": b["localId"], "file": b["file"], "hash": b["hash"]}) + "\n")
            f.flush()
            n += 1
            if n % 200 == 0:
                print(f"uploaded {n} of {len(todo)}")
    print(f"uploaded {n}")


if __name__ == "__main__":
    {"prep": prep, "upload": upload}[sys.argv[1]]()
