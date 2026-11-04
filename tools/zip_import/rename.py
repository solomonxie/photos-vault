"""What the app's Fix Names does to an upload, done from the Mac: each
`import_<stamp>_…` original (and its thumbnail) gets the app's own name,
`<stamp>_<sha256(old key)[:16] hex>`, so Suggestions offers it under Add to
Library instead of a three-hour rename on the phone. Copy, check the size,
then delete the old name. Logged to $WORK/renamed.jsonl; re-runs skip it."""

import hashlib
import json
import os
from concurrent.futures import ThreadPoolExecutor

from upload import WORK, client


def main():
    s3, bucket, prefix = client()
    done_path = os.path.join(WORK, "renamed.jsonl")
    done = set()
    if os.path.exists(done_path):
        done = {json.loads(l)["from"] for l in open(done_path)}
    todo = [json.loads(l) for l in open(os.path.join(WORK, "uploaded.jsonl"))]
    todo = [d for d in todo if d["key"] not in done and "/import_1969" not in d["key"]]
    print(f"to rename: {len(todo)}", flush=True)

    def move(old, new):
        size = s3.head_object(Bucket=bucket, Key=old)["ContentLength"]
        if size > 5 * 1024 ** 3:
            raise RuntimeError(f"too big for one copy: {old}")
        s3.copy_object(Bucket=bucket, Key=new, CopySource={"Bucket": bucket, "Key": old})
        if s3.head_object(Bucket=bucket, Key=new)["ContentLength"] != size:
            raise RuntimeError(f"size mismatch {new}")
        s3.delete_object(Bucket=bucket, Key=old)

    def one(d):
        old = d["key"]
        name = old.rsplit("/", 1)[-1]
        stem, ext = name.rsplit(".", 1)
        stamp = stem.split("_")[1]
        base = f"{stamp}_{hashlib.sha256(old.encode()).hexdigest()[:32]}"
        new = f"{prefix}/originals/{base}.{ext}"
        move(old, new)
        try:
            move(f"{prefix}/thumbnails/{stem}.jpg", f"{prefix}/thumbnails/{base}.jpg")
        except Exception as e:
            print("thumbnail:", str(e)[:120], flush=True)
        return {"from": old, "to": new, "sha256": d["sha256"]}

    n = failed = 0
    with ThreadPoolExecutor(16) as ex, open(done_path, "a") as log:
        for f in [ex.submit(one, d) for d in todo]:
            try:
                log.write(json.dumps(f.result()) + "\n")
                log.flush()
                n += 1
            except Exception as e:
                failed += 1
                print("failed:", str(e)[:160], flush=True)
            if (n + failed) % 500 == 0:
                print(f"renamed {n}, failed {failed}", flush=True)
    print(f"renamed {n}, failed {failed}")


if __name__ == "__main__":
    main()
