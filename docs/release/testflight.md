# TestFlight external testing

App Store Connect → TestFlight → External Testing → **+** group → add the build. First build of a version goes through Beta App Review (~1 day).

## Test Information

Beta App Description (≤4000):

```
Photos Vault backs up your photos and videos to a bucket you own (AWS S3, Tencent COS, Alibaba OSS) and works as a gallery while it does: day grid, albums, tags, captions, places, Live Photos and video, on-device face recognition, and private albums behind a 4-digit code.

No account with us. Backup needs your own bucket credentials; everything else works without one. To look around with sample data: bottom of the home page → Demo Mode (isolated store; your library and iCloud untouched). The demo private album opens with code 1234.

What's in this beta:
• Automatic, resumable backup to one or more buckets, HEIF or original, with a readable index.csv in every backup
• Check Now and Test Restore verify the bucket before anything local is deleted
• Gallery: grid, albums, tags, captions, places, crop/rotate
• People: on-device face recognition
• Private albums (any code opens its own album)
• Free-up-space tools
• Optional AI (your own key) to fill person profiles from text; no photo is ever sent to AI
• English and Simplified Chinese
```

Feedback Email: `you@example.com`

## Contact Information

| Field | Value |
|---|---|
| First Name | TODO |
| Last Name | TODO |
| Phone number | TODO — yours, with country code (`+1 …`) |
| Email | `you@example.com` |

## Sign-In Information

Sign-in required: **off** (no account in the app). Leave User Name / Password blank.

Review Notes (Beta App Review Information):

```
No account or login. For a full sample gallery without any cloud setup: bottom of the home page → Demo Mode; the demo private album code is 1234. Backup needs the user's own bucket. To test a real upload use this throwaway bucket (least-privilege IAM user, deleted after review): Provider: AWS S3 · Bucket: TODO · Region: TODO · Access key ID: TODO · Secret access key: TODO. Enter it under More → Cloud Settings → Add Cloud Bucket. Deleting from Photos always goes through the iOS confirmation sheet.
```

## Per build: What to Test

```
Turn on Demo Mode at the bottom of the home page: browse the grid, albums and People, open the private album with code 1234, then turn it off. With your own library: grant access, tag a few photos, let People find faces. If you have an S3-compatible bucket: More → Cloud Settings → Add Cloud Bucket, back up a few photos, run Check Now and Test Restore. Report anything slow or wrong with a screenshot via TestFlight.
```
