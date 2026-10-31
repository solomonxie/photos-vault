# Setup

The first page on first run, and later reached from ⚙ in the sidebar.

```
╔══════════════════════════════════════════════════════════════════════════╗
║                                                                          ║
║                 Photos Vault                                             ║
║                 Your library, from your own bucket.                      ║
║                                                                          ║
║     BUCKET                                    ( Paste connection info )  ║ ← swaps the fields for
║     Provider    [ AWS S3 | Tencent COS | Alibaba OSS ]                   ║   a paste box in place
║     ┌──────────────────────────────────────────────┐                     ║
║     │ Bucket name                                  │                     ║
║     └──────────────────────────────────────────────┘                     ║
║     ┌──────────────────────────────────────────────┐                     ║
║     │ Access key ID                                │                     ║
║     └──────────────────────────────────────────────┘                     ║
║     ┌──────────────────────────────────────────────┐                     ║
║     │ ••••••••••••••••••••••••••••••••••••••   👁  │ Secret access key   ║
║     └──────────────────────────────────────────────┘                     ║
║     ┌──────────────────────────────────────────────┐                     ║
║     │ Key prefix (optional), e.g. photos/          │                     ║ ← must match the
║     └──────────────────────────────────────────────┘                     ║   phone's home bucket
║     ▸ Advanced  (region override)                                        ║
║                                                                          ║
║     Stored only in this Chrome profile, never synced to your Google      ║
║     account. Use a key limited to this one bucket.                       ║
║                                                     [[ Connect ]]        ║
╚══════════════════════════════════════════════════════════════════════════╝
```

Reached from: toolbar icon with no connection · ⚙ → Connection

## Paste mode
```
║     BUCKET                                          ( Back to fields )   ║
║     ┌──────────────────────────────────────────────┐                     ║
║     │ bucket: sol-photos                           │                     ║ ← parsed on every
║     │ prefix: vault/                               │                     ║   change, rules in
║     │ access_key_id: AKIA4…                        │                     ║   paste-to-fill.md
║     │ secret_access_key: wJal…                     │                     ║
║     └──────────────────────────────────────────────┘                     ║
║     Shown unmasked so a bad paste is visible.                            ║
```

## States
```
saving    ⟳ Asking Chrome for access to sol-photos…   ← host permission prompt, Chrome's own
          ⟳ Detecting region…
          ⟳ Checking bucket access…
fail      ⚠ AccessDenied: Access Denied                 fields untouched, Connect re-enabled
          The key can't list sol-photos/vault/. Check its policy allows s3:ListBucket.
no lib    ⚠ No Photos Vault library in sol-photos/vault/
          Check the prefix matches the bucket set on your phone.   ( Use it anyway )
denied    ⚠ Chrome access to the bucket was declined.   [ Try again ]
draft     Recent attempts                                  ← keyed bucket+prefix+key id
          sol-photos/vault/ · AKIA4…           Fill   ✕
```

## Waiting for phone
```
╔══════════════════════════════════════════════════════════════════════════╗
║                                                                          ║
║                   ⟳                                                      ║
║          Waiting for your phone                                          ║
║          Open Photos Vault on your iPhone and turn on                    ║
║          Settings › Cloud Sync. Your library appears here as soon        ║
║          as the phone has published it.                                  ║
║                                                                          ║
║          Checking every 10 s.                    ( Change connection )   ║
╚══════════════════════════════════════════════════════════════════════════╝
```

## Copy
| Key | String |
|---|---|
| `setup.title` | Photos Vault |
| `setup.subtitle` | Your library, from your own bucket. |
| `setup.connect` | Connect |
| `setup.scopeHint` | Stored only in this Chrome profile, never synced to your Google account. Use a key limited to this one bucket. |
| `setup.noLibrary` | No Photos Vault library in {bucket}/{prefix} |
| `waiting.title` | Waiting for your phone |
