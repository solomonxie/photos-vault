# Privacy Policy — Photos Vault

_Last updated: 2026-09-22_

Photos Vault has no server and no account. Nothing you do in the app is sent
to its developer, and there is nowhere for it to be sent to.

## What stays on your device

Your photo library records, albums, people, faces, tags, captions, places and
settings are kept in databases on the iPhone. Face detection, face matching,
grouping and search all run on the device. Deleting the app deletes all of it.

## What leaves the device, and only where you send it

- **Your storage bucket** — photos and videos are uploaded to a bucket you
  provision (Amazon S3, Tencent COS, Alibaba Cloud OSS) using credentials you
  supply. The bucket is yours; the developer has no access to it and never
  sees the credentials.
- **Private albums** — photos you hide are encrypted on the device before
  they leave it (AES-256, key derived from your passphrase) and stored in
  your bucket disguised as ordinary pictures. The passphrase never leaves the
  device. Without it nothing, including this app, can open them.
- **Your iCloud Drive** — optional. A copy of the app's own records (albums,
  people, tags, captions — not the photos) can be written to your iCloud
  account, under your quota.
- **AI analysis and AI touch-up** — off by default, and only after you add
  your own API key. When enabled, a photo and your prompt go to the vendor
  whose key you configured (OpenAI, Anthropic, Google, Groq, Mistral, xAI)
  under your own account with them, billed to you and governed by their
  privacy policy. The key is stored in the iOS Keychain and is never sent to
  the developer.
- **Reverse geocoding** — when a photo carries GPS coordinates and you view
  its place, those coordinates go to Apple's geocoding service to be turned
  into a place name. No identifier is attached.

## Permissions

- **Photos** — to read your camera roll for backup, and to put a photo back
  when you take it out of a private album. Access can be limited to selected
  photos, and the app works with whatever you grant.

## Security

Bucket credentials, AI keys and private-album key material are stored in the
iOS Keychain, device-only, and are never included in any backup the app
writes. All network traffic uses HTTPS.

## Analytics and advertising

None. No analytics SDK, no crash reporting service, no advertising
identifier, no tracking across apps or websites.

## Children

The app is not directed at children and collects no data from anyone.

## Deleting your data

Deleting the app removes everything stored locally. Files already in your own
bucket or iCloud Drive remain yours to delete.

## Changes

Material changes will be published here with a new date.

## Contact

https://github.com/solomonxie/photos-vault/issues
