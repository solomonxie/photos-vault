"""The user's library as the app sees it: the fullest recent app-data
snapshot in the bucket. Read-only on the bucket."""

import io
import json
import os
import re
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


DEVICE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
LEGACY_LOOKBACK = 15


def candidates(keys, base):
    """Each device folder's newest daily (`app-data/<device>/YYYYMMDD.zip`),
    plus the newest few of the old shared layout (`app-data/YYYYMMDD.zip`),
    which any device may have overwritten."""
    by_device = {}
    for k in keys:
        rel = k[len(base):].split("/")
        name = rel[-1]
        if not (name.endswith(".zip") and name[:8].isdigit() and name[:2] == "20"):
            continue
        if len(rel) == 1:
            by_device.setdefault(None, []).append(k)
        elif len(rel) == 2 and DEVICE.match(rel[0]):
            by_device.setdefault(rel[0], []).append(k)
    out = []
    for device, ks in by_device.items():
        ks.sort(key=lambda k: os.path.basename(k))
        out += ks[-LEGACY_LOOKBACK:] if device is None else ks[-1:]
    return out


def snapshot(refresh=False):
    """The newest candidate not clearly thinner (a quarter fewer photos,
    albums and people) than the fullest, as the app's restore picks. A
    cloud-only phone's thin copy must not stand in for the library."""
    path = os.path.join(WORK, "library.json")
    if refresh or not os.path.exists(path):
        s3, bucket, prefix = client()
        base = f"{prefix}/app-data/"
        keys = []
        for page in s3.get_paginator("list_objects_v2").paginate(
            Bucket=bucket, Prefix=base
        ):
            keys += [o["Key"] for o in page.get("Contents", [])
                     if "/blobs/" not in o["Key"]]
        found = []
        for key in candidates(keys, base):
            body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            with zipfile.ZipFile(io.BytesIO(body)) as z:
                raw = z.read("library.json")
            lib = json.loads(raw)
            rows = (len(lib.get("assets", [])) + len(lib.get("albums", []))
                    + len(lib.get("people", [])))
            found.append((rows, os.path.basename(key)[:8], key, raw))
        most = max(f[0] for f in found)
        rows, _, key, raw = max((f for f in found if f[0] * 5 >= most * 4),
                                key=lambda f: (f[1], f[0]))
        with open(path, "wb") as f:
            f.write(raw)
        print("snapshot", key, rows, "rows")
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
