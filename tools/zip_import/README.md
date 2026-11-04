# Photo zips into the bucket

Google Photos downloads (or any zip of photos and videos) into the bucket,
the way the phone backs up, for Cloud Settings → Import from Bucket.

```text
zips ─survey.py─▶ survey.jsonl   date, size, already in the library?
                  (camera date, else one in the name; library match = same
                   pixels and moment, any whole-hour time zone)
dates.jsonl      dates found later for the undated, by sha256
                  (names; else the same camera's neighbouring numbers;
                   else the zip's own order)
      ─upload.py─▶ <prefix>/originals/import_<YYYYMMDDHHMMSS>_<12 hex>.heif|<video>
                   <prefix>/thumbnails/…jpg (512 px)
phone: Cloud Settings → Import from Bucket — renames, makes cloud records
```

- Nothing without a date is sent; the date in the name is what the app
  falls back to when the file has none.
- Stills → HEIF (`sips`, quality 82, EXIF kept); GIFs and videos as-is.
- Re-runs skip what `uploaded.jsonl` lists.

```sh
WORK=/tmp/zip-import tools/zip_import/venv/bin/python tools/zip_import/survey.py <photos_vault.db copy> ZIP...
WORK=/tmp/zip-import tools/zip_import/venv/bin/python tools/zip_import/upload.py
```
