"""The user's library as the app sees it: the newest app-data snapshot in the
bucket. Read-only on the bucket."""

import io
import json
import os
import zipfile

import boto3

from store import WORK

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def env():
    out = {}
    with open(os.path.join(ROOT, ".env.bucket")) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k] = v.strip().strip("'\"")
    return out


def client():
    e = env()
    s3 = boto3.client(
        "s3",
        aws_access_key_id=e["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=e["AWS_SECRET_ACCESS_KEY"],
        region_name=e.get("AWS_DEFAULT_REGION"),
    )
    return s3, e["BUCKET"], e["PREFIX"]


def snapshot(refresh=False):
    path = os.path.join(WORK, "library.json")
    if refresh or not os.path.exists(path):
        s3, bucket, prefix = client()
        keys = []
        for page in s3.get_paginator("list_objects_v2").paginate(
            Bucket=bucket, Prefix=f"{prefix}/app-data/"
        ):
            keys += [o["Key"] for o in page.get("Contents", [])]
        dated = sorted(k for k in keys if os.path.basename(k)[:8].isdigit()
                       and os.path.basename(k)[:2] == "20" and k.endswith(".zip"))
        body = s3.get_object(Bucket=bucket, Key=dated[-1])["Body"].read()
        with zipfile.ZipFile(io.BytesIO(body)) as z, open(path, "wb") as f:
            f.write(z.read("library.json"))
        print("snapshot", dated[-1])
    with open(path) as f:
        return json.load(f)


def open_photos(lib, archived=True):
    """Stills with an original in the bucket, archived (zip-imported) ones
    included unless [archived] is False. Hidden, binned and videos are left
    out."""
    out = []
    for a in lib["assets"]:
        if a.get("passcodeHash") or a.get("deletedAt") or a.get("isVideo"):
            continue
        if a.get("isArchived") and not archived:
            continue
        key = ((a.get("derivatives") or {}).get("original") or {}).get("destinationKey")
        if key:
            out.append((a["localId"], key))
    return out


def manual_labels(lib):
    """{localId: [person name]} on library photos only: zip-imported people
    tag archived photos, and their labels are too dirty to seed from."""
    ok = {lid for lid, _ in open_photos(lib, archived=False)}
    out = {}
    for p in lib["people"]:
        for lid in p.get("localIds", []):
            if lid in ok:
                out.setdefault(lid, []).append(p["name"])
    return out


def stem(key):
    return os.path.splitext(os.path.basename(key))[0]
