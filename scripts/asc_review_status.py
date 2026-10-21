#!/usr/bin/env python3
"""App Store / TestFlight review status from the App Store Connect API.

Config (outside the repo): ~/.appstoreconnect/config.env with
ASC_KEY_ID=..., ASC_ISSUER_ID=..., optional ASC_KEY_PATH (default
~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8).
Bundle id comes from APP_BUNDLE_ID in ios/Flutter/*.xcconfig.

Prints the current states; exit 0 unchanged, 10 changed since last run.
The API exposes states only: Resolution Center message text and replies
are web-only.

Run: venv/bin/python scripts/asc_review_status.py
"""
import base64
import json
import pathlib
import re
import sys
import time

import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

HOME = pathlib.Path.home() / ".appstoreconnect"
STATE = HOME / "photos-vault-review-state.json"
REPO = pathlib.Path(__file__).resolve().parent.parent
API = "https://api.appstoreconnect.apple.com/v1"


def config():
    env = {}
    for line in (HOME / "config.env").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"')
    path = env.get("ASC_KEY_PATH") or str(
        HOME / "private_keys" / f"AuthKey_{env['ASC_KEY_ID']}.p8")
    return env["ASC_KEY_ID"], env["ASC_ISSUER_ID"], pathlib.Path(path).expanduser()


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token(key_id, issuer, key_path):
    key = serialization.load_pem_private_key(key_path.read_bytes(), None)
    head = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    now = int(time.time())
    body = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 1200,
                           "aud": "appstoreconnect-v1"}).encode())
    der = key.sign(f"{head}.{body}".encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return f"{head}.{body}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def bundle_id():
    for f in sorted((REPO / "ios" / "Flutter").glob("*.xcconfig")):
        m = re.search(r"^\s*APP_BUNDLE_ID\s*=\s*(\S+)", f.read_text(), re.M)
        if m:
            return m.group(1)
    sys.exit("APP_BUNDLE_ID not found in ios/Flutter/*.xcconfig")


def get(session, path, **params):
    r = session.get(f"{API}/{path}", params=params, timeout=30)
    r.raise_for_status()
    return r.json()["data"]


def main():
    s = requests.Session()
    s.headers["Authorization"] = f"Bearer {token(*config())}"
    apps = get(s, "apps", **{"filter[bundleId]": bundle_id()})
    if not apps:
        sys.exit("App not found for this bundle id")
    app = apps[0]["id"]
    state = {
        "versions": [
            {"version": v["attributes"]["versionString"],
             "platform": v["attributes"]["platform"],
             "state": v["attributes"].get("appStoreState")}
            for v in get(s, f"apps/{app}/appStoreVersions", limit=5)],
        "submissions": [
            {"id": r["id"], "state": r["attributes"].get("state"),
             "submitted": r["attributes"].get("submittedDate")}
            for r in get(s, "reviewSubmissions", limit=5,
                         **{"filter[app]": app})],
        "beta": [
            {"build": b["id"], "state": b["attributes"].get("betaReviewState")}
            for b in get(s, "betaAppReviewSubmissions", limit=5,
                         **{"filter[build.app]": app})],
        "builds": [
            {"version": b["attributes"]["version"],
             "processing": b["attributes"].get("processingState"),
             "uploaded": b["attributes"].get("uploadedDate")}
            for b in get(s, "builds", limit=5, sort="-uploadedDate",
                         **{"filter[app]": app})],
    }
    print(json.dumps(state, indent=2))
    old = json.loads(STATE.read_text()) if STATE.exists() else None
    STATE.write_text(json.dumps(state))
    if old != state:
        print("CHANGED" if old is not None else "FIRST RUN")
        return 10 if old is not None else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
