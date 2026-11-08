# Photo zips into the bucket

Google Photos downloads (or any zip of photos and videos) into the bucket,
the way the phone backs up, straight into the library through the cloud log.

```text
zips ─survey.py─▶ survey.jsonl   date, size, already in the library?
                  (camera date, else one in the name; library match = same
                   pixels and moment, any whole-hour time zone)
dates.jsonl      dates found later for the undated, by sha256
                  (names; else the same camera's neighbouring numbers;
                   else the zip's own order)
      ─upload.py─▶ <prefix>/originals/<stamp>_<sha256(import key)[:32]>.heif|<video>
                   <prefix>/thumbnails/…jpg (512 px)
                   (the app's own names; import key = import_<YYYYMMDDHHMMSS>_<12 hex>)
      ─publish_log.dart─▶ an `asset` add per photo in the cloud log, from a
                          Mac device: every phone makes a cloud record on
                          its next sync (no Suggestions step)
```

- Nothing without a date is sent; the date in the name is what the app
  falls back to when the file has none.
- Stills → HEIF (`sips`, quality 82, EXIF kept); GIFs and videos as-is.
- Re-runs skip what `uploaded.jsonl` lists.
- Adds only: a key already in the bucket is skipped, never written over;
  nothing is deleted. `rename.py` is left for older `import_` uploads only.

```sh
WORK=/tmp/zip-import tools/zip_import/venv/bin/python tools/zip_import/survey.py <photos_vault.db copy> ZIP...
WORK=/tmp/zip-import tools/zip_import/venv/bin/python tools/zip_import/upload.py
WORK=/tmp/zip-import .tools/flutter/bin/flutter test tools/zip_import/publish_log.dart
```
