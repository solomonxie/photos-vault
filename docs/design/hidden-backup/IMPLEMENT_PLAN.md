# Implementation plan — hidden photos as carriers

Design: [`DESIGN.md`](DESIGN.md). **Built** — `lib/vault/`,
`lib/upload/pending_deletes.dart`, `ios/Runner/StillVideoChannel.swift`.

Not yet exercised against a real bucket or a real hidden video on a phone:
everything below is covered by unit tests and a release build, which is not
the same thing. See "Still to prove" at the end.

## P0 — stop today's leaks (independent, shippable alone)

- [x] `_backUpRecords`: skip `uploadThumbnail` / `uploadLivePhoto` for a
      record with a `passcodeHash`. One `if`, beside the sync-off gate.
- [x] Hiding deletes what is already up — `originals/<id>.*` and
      `thumbnails/<id>.jpg`, every target. Unhiding re-enqueues a normal
      backup.
- [x] Pending-deletes table: never expires, retries on reconnect, ends only
      on success, on a 404, or when the photo itself is deleted. A 403 is
      not a 404.
- [x] Move `thumbnail_cache` off Application Support (in the iOS device
      backup) to `Library/Caches` (`getApplicationCacheDirectory`); clear
      what is already there on upgrade. Hidden records write no plain
      thumbnail at all.
- [x] Rewrite `lib/upload/README.md`'s "exactly one path deletes from a
      bucket" — this is the second.
- [x] Prompt at hide time about Photos' Recently Deleted, with a button that
      opens Photos there.
- [x] Tests: a hidden record enqueues one job; hiding a backed-up photo
      queues both deletes; a failed delete retries rather than resolving.

## P1 — crypto floor

- [x] `lib/vault/vault_cipher.dart` — `deriveKey`, `encryptStream`,
      `decryptStream`, `hmac`.
- [x] `lib/vault/commoncrypto_cipher.dart` — `dart:ffi` to
      `CCKeyDerivationPBKDF`, `CCCryptorCreate/Update/Final`. AES-256-CTR.
- [x] Encrypt-then-MAC with `crypto`'s HMAC, 1 MB chunks, on an isolate.
- [x] Tests: NIST AES-CTR and RFC 4231 vectors; 5 MB round trip.

## P2 — passphrase & key ring

- [x] `lib/vault/master_key.dart` — PBKDF2 600k, 16 B salt, `masterKey` into
      `SecureStore`. A **set** of entries, merged on restore, never dropped;
      active = newest.
- [x] Setup prompt: passphrase + hint, one screen, no fork, no verdict,
      minimum length enforced, the hint's cost stated.
- [x] `lib/vault/album_key_ring.dart` — `HKDF(masterKey, 4 digits)` per
      unlock, RAM only.
- [x] *Forget the passphrase on this phone* (a Keychain item survives a
      reinstall on iOS).
- [x] Optional memory-only mode, default off.
- [x] Tests: wrong digits derive a different album key and open nothing,
      with no error path; the ring empties on drop; two passphrases coexist.

## P3 — the index

- [x] `app-data/index.bin` — written by **every** install, hidden photos or
      not. Fixed size, fixed section count, padded with decoy sections.
      Section tag = `HMAC(albumKey, "section")`.
- [x] Plaintext header: version, KDF salt, verifier, hint. Keychain instead
      while no bucket is configured.
- [x] Rewritten on hide/unhide *and* on a schedule; `If-Match` where
      supported, union on conflict.
- [x] Rebuild by scanning objects' first 64 KB when missing.
- [x] Tests: a wrong code matches no section; the object is the same size
      with 0 and with 200 hidden photos; a never-hidden install still
      writes it.

## P4 — carrier read/write

- [x] `lib/vault/jpeg_segments.dart` — parse a JPEG into segments, insert
      `APP7` chains before `DQT`, serialise. Pure Dart, isolate-safe.
- [x] `lib/vault/carrier.dart` — `buildCarrier(decoy, thumb, original, key)`,
      `openCarrier(bytes, keys)`, `openThumbnail(first64k, keys)`. Two
      chains, header and locator per DESIGN, one IV per payload.
- [x] Decoy builder: the non-hidden record whose **own file size is closest
      to the payload's**, tie-broken at random among the nearest few; its
      cached thumbnail upscaled to that record's resolution, q≈50, wearing
      that record's EXIF date. Never nearest-in-time. No decoy twice over.
      Nothing about the choice persisted.
- [x] `lib/vault/mp4_boxes.dart` + video carriers: payload in a `free` box
      after `moov` (no offset rewriting). Decoy = the first frame of the
      non-hidden video closest in size to the payload, held for that video's
      own duration at its resolution and frame rate, long keyframe interval.
      Live Photo `.mov` halves take this path.
- [x] Test: the carrier's bytes ÷ duration lands in the range real captures
      occupy; it plays in QuickTime and iOS Photos; no box is malformed.
- [x] Payload: the original as-is (HEIC never re-encoded), or the optimized
      WebP when that format is set.
- [x] Tests: the carrier decodes as an image of the decoy's dimensions; no
      bytes past `EOI`; a tampered byte fails the MAC; 64 KB is enough for
      the thumbnail; the hidden photo's date appears nowhere; measure the
      real overhead on a 12 MP fixture (the ~10 % claim is a prediction
      until this runs).

## P5 — wire into the pipeline

- [x] `BackupCoordinator._resolveUploadPath`: hidden record + key in the
      ring → carrier temp file, reusing the existing temp-file ownership.
- [x] Hidden record with no key in the ring → the job waits, not fails.
- [x] On confirmed upload: add the index entry, then **delete the local file
      and the record**.
- [x] Opaque `displayName` for hidden sync jobs.
- [x] Grid tile = 64 KB ranged GET via `http` + presigned URL, decrypt,
      decode, into a bounded RAM LRU. Prefetch ahead of the scroll.
- [x] Disk cache in `Library/Caches`: encrypted with the album key, names
      `HMAC(albumKey, objectKey)`, three pools with their own caps and TTLs
      (thumbnails 100 MB / 7 d, photos 500 MB / 24 h, videos 2 GB / 30 d),
      LRU inside each, whole cache dropped when the passphrase is forgotten.
- [x] Full photo on demand; unhide writes it back into Photos, deletes the
      carrier, removes the index entry.
- [ ] **Unhiding from the bucket must set the creation date**, the same way
      `LibraryCustody` now does for a local put-back: PhotoKit stamps what
      it creates with *now*, so a photo hidden in 2019 comes back dated
      today. The date is in the index entry (`takenAt`).
- [x] Videos: MP4 carriers per DESIGN, or keep local if that lands later.
- [x] Tests: hide → upload → row gone → restore; a locked album uploads
      nothing; the local original survives until the carrier is confirmed;
      nothing for a hidden record ever reaches the cache directory.

## P6 — copy and docs

- [x] Rewrite `privateAlbumBackupExplainer` (en + zh): encrypted now, the
      network requirement, the video exception, Recently Deleted.
- [x] Album footer: passphrase list, outstanding deletions, delete-this-
      generation.
- [x] `docs/design/uiux/collections.md`, `lib/upload/README.md`,
      `lib/vault/README.md`.
- [x] Size check with `--analyze-size` before and after: headroom is
      0.8 MB, the target is under 0.2 MB, and the risk is `image` package
      retention from a new call rather than anything this adds deliberately.

## Still to prove

- [ ] A hidden photo, end to end, against a real bucket: carrier up, record
      gone, tile drawn from a ranged GET, photo opened again.
- [ ] A hidden **video** on a device — the held-frame encoder has compiled
      and shipped but never run.
- [ ] Two phones, one bucket, two passphrases.
- [ ] What a 12 MP carrier costs in wall-clock time on the phone: the
      upscale, encode and encrypt are all measured on a laptop so far.
