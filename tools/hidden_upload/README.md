# Hidden upload from the Mac

The phone's hidden backup, run on a Mac: same code, same carriers, the
bucket sends faster than the phone does.

```text
phone (USB) ──devicectl──▶ one plain file ─build_carriers.dart─▶ carrier
                             deleted at once      (app's own vault code,
                                                   opened back and checked)
carrier ──bucket.py upload──▶ <prefix>/originals/<carrier name>
uploaded.jsonl ──devicectl──▶ phone Documents/mac-uploads.jsonl
                              └─ app: MacUploads.adopt() (HEAD, mark uploaded)
```

- Keys: `.env.vault` (gitignored) — `PASSPHRASE=` and `DIGITS1=`… The
  passphrase is checked against the bucket's `index.bin`; folder codes are
  the digits per person, as on the phone.
- Bucket: `.env.bucket`, the phone's one hidden-backup target.
- Plain photos are on the Mac one at a time, only while being encrypted.

## Run

```sh
W=/tmp/pv-hidden-upload; mkdir -p $W
# fresh photos_vault.db + people.db from the phone into $W (devicectl copy from)
PV_WORK=$W tools/hidden_upload/venv/bin/python tools/hidden_upload/bucket.py prep
PV_WORK=$W PV_VAULT_ENV=$PWD/.env.vault PV_MODE=build PV_LIMIT=0 PV_DEVICE=<udid> \
  .tools/flutter/bin/flutter test tools/hidden_upload/build_carriers.dart
PV_WORK=$W tools/hidden_upload/venv/bin/python tools/hidden_upload/bucket.py upload
xcrun devicectl device copy to --device <udid> --domain-type appDataContainer \
  --domain-identifier com.solomonxie.photosVault \
  --source $W/uploaded.jsonl --destination Documents/mac-uploads.jsonl
```

`PV_MODE=check` only reports what the keys open. Re-runs skip what
`built.jsonl` / `uploaded.jsonl` already list. Delete `$W` after.
