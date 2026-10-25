# Face recognition — same person across photos

> **Removed, 25 Oct 2026.** On-device matching (SFace, descriptors, guesses,
> "find more", phone-side Faces to Name) was too inaccurate to trust. Names
> now come only from the Mac import (`MAC-PIPELINE.md`). The phone keeps
> Vision face *detection* (boxes, crops, profile photos, tap a face to name
> it); `face_descriptor` rows are just face ↔ person links, vector empty.
> Below is the record of what was built.

## Problem
The app finds faces (Vision) but never who they belong to, so every photo of
the same person is named by hand. On a real camera roll that is thousands of
identical answers to the same question, and People stays empty because nobody
finishes. Picks up the "on-device clustering as a later stretch goal" left
open in `../DESIGN.md` → Options considered → Person identity.

## Goals
- Suggest a name for a newly-found face by matching it against faces already
  confirmed for a named person.
- On-device, offline, no bundle growth, no per-photo bill — the same terms as
  the free half of the analyze pass.
- Suggest, never assert. One tap to accept, and a wrong guess costs nothing.
- Runs inside the existing analyze queue: paced, pausable, resumable.

## Non-goals
- **Unattended clustering.** Nothing groups the library into piles on its
  own and asks you to name them — a wrong pile is worse than no pile, and it
  would be *stored* wrongness. Grouping happens only when you point at a face
  and ask "who else looks like this?", it is computed fresh each time, and it
  is not written down until you give it a name. Same mechanism, no
  accumulating mistakes.
- **Auto-tagging.** Nothing is linked without a tap.
- **Android.** Vision is iOS-only; elsewhere the feature is simply absent and
  faces keep reading "Who's this?".
- Syncing descriptors between devices, or putting them in the bucket backup.

## Options considered
- **`VNGenerateImageFeaturePrintRequest` over the face crop** — in the
  iPhoneOS 27 SDK, ships with iOS, 0 bytes of bundle, `computeDistance` gives
  a similarity out of the box. It is a *general image* descriptor, not
  face-trained, so accuracy is the open risk.
- **Bundle a CoreML face-embedding model** (MobileFaceNet class, ~4–5 MB) —
  genuinely accurate; blows the 25 MB budget, which stands at 22.3 MB.
- **Download that model on first use** — keeps the budget, adds a network
  dependency and a "downloading…" state to a feature that is otherwise
  offline. Kept as the escape hatch if option 1 measures badly.
- **Vision face landmarks + hand-rolled geometry** — free, and useless the
  moment the head turns.
- **A vendor vision API** (keys already supported) — accurate, but a bill per
  photo across the whole library and every face leaves the device. The paid
  step is opt-in for tags; identity is not worth that trade.

## Decision (revised — the model shipped)
**SFace**, bundled. OpenCV Zoo's model, Apache-2.0, converted from ONNX and
quantised to int8 by `scripts/convert_sface.py`: 9.3 MB of `.mlmodelc` in the
bundle, 128-d embedding, 112x112 aligned input. Verified faithful to the
reference at 0.997 cosine after quantisation.

The size budget in `CLAUDE.md` went from 25 MB to 33 MB to make room. That
was the trade offered and taken: no face model small enough for the old
budget exists under a licence worth shipping — MobileFaceNet repos are empty
or unlicensed, EdgeFace is non-commercial — and the general descriptor below
could not tell two people apart well enough to be worth the taps.

Its threshold is the one number here nobody invented: SFace's authors publish
0.363 cosine *similarity* as the same-person line, so 0.637 distance.

What follows is the reasoning for the general-descriptor version, kept
because it is still what runs for a face whose eyes Vision can't find, and
because it is the fallback if the model ever fails to load.

Option 1. The measurement that was meant to gate this can't come first: a
same-person/different-person distance distribution needs labelled faces, and
the only labels that exist are the ones the user makes by naming people. So
the threshold ships provisional, in one named constant, and is tuned on real
suggestions (IMPLEMENT_PLAN T5.0). Descriptors come from Vision on a **tight** crop — tighter than the
45%-padded display crop, because a general image descriptor will happily match
the beach behind two different people.

**Every face's descriptor is stored** (revised — it was confirmed faces only).
A descriptor is ~3–8 KB, so a library with five thousand faces in it costs
15–40 MB of database. That was judged too much for what it bought, back when
all it bought was a reference set: one per *confirmed* face answers "who is
this?" just as well and costs a few MB.

It buys more than that. Grouping from any face — "show me everyone who looks
like this one" — needs the candidates' descriptors, not just the confirmed
ones, and recomputing thousands of them per tap is not a feature, it's a
freeze. Storing them also means one Vision pass per face ever, instead of one
per face per matching run.

Against a photo library measured in gigabytes, tens of megabytes of vectors is
the cheaper half of the trade.

The crop is prepared before Vision sees it: **aligned** on the eyes where
Vision can find them — levelled, scaled so the eyes always land in the same
two places — then drawn as a fixed-size **grey square**. Two photos of one
person differ most in how the head is turned and how big it is in frame,
neither of which is anything to do with who they are. A face whose eyes
can't be found still gets described, in its own space (pipeline 2 rather
than 3), so those group among themselves instead of polluting everything
else. The print describes an *image*, not a face, so
everything else that varies between two crops lands in the answer — colour,
which made a warm room match a warm room rather than a person match a person,
and size, which made a close-up and a face across the room different kinds of
thing before they were different people. The preprocessing version travels
with the vector alongside Vision's own revision: a print of a colour crop and
a print of a grey square are not two answers to one question, so changing it
re-describes rather than compares.

Distance is **cosine**, not L2: 0 for the same direction, ~1 for unrelated, 2
for opposite. Plain L2 has no scale anybody can reason about — Vision's
vectors come back roughly unit-length, so real distances sat well under 1
while the threshold guarding them was 26. Everything passed, and every face
grouped with every other face in the library. Cosine also makes the same face
photographed darker the same answer, which L2 called a different person.

Matching is nearest-neighbour over the stored descriptors with two gates: a
distance ceiling, and a margin between the best person and the runner-up.
Failing either gives no suggestion, which is the current behaviour and a fine
outcome.

Grouping carries a second guard the matcher doesn't need: a cap on how many
faces come back. A threshold can be wrong, and when it is, the page should
still be a page somebody can read rather than the whole library.

## Data & integrations
- New Swift method `featurePrint(path, rect)` on the existing
  `byo.photos/vision` channel → `Float32` vector + the request revision.
- New table in the analysis DB: `face_descriptor(local_id, face, person_id,
  revision, vector BLOB)` — one row per confirmed face.
- Written when a face is linked to a person; deleted with the person.
- Excluded from the app-data change log and the zip backup (Files, iCloud
  Drive, bucket): derivable from the photos and the person links, and bulky.
  They are in the raw `ai_analysis.db` rollback copies on the phone (and so
  in an iPhone backup), minus hidden photos' faces, which hiding deletes.
- Cost: one extra Vision pass per unnamed face during analysis, and one per
  face at confirm time. No network, no money.
- Boxes, crops and descriptors all come from one upright decode (EXIF
  applied, ≤ 2048 px), one native call per photo. Rows from before
  analysis v7 were measured on the raw sensor buffer; the analyze pass reads
  each one's orientation once and turns its boxes, descriptor keys and any
  avatar box upright.
- Re-describing (a new pipeline) replaces the vector, never the name.
- Finding faces again carries each descriptor to the new box it overlaps
  (IoU ≥ 0.5), names first; an unnamed one with no box is dropped.
- If SFace doesn't load, the aligned print (pipeline 3) is a live space:
  kept, not re-described every run. The analyze page says why.

## Risks / open questions
- **Accuracy is unproven.** A general descriptor may not separate faces well
  enough to be worth the taps. Phase 1 measures it against a real library
  before anything else is built; if it fails, the decision flips to the
  downloaded model.
- **It does not improve with library size.** The model is fixed and never
  learns. What improves a person's match rate is more *confirmed* faces for
  that person — more angles, more light, more years — so accuracy climbs
  steeply over the first handful of confirmations and then plateaus. More
  unnamed photos add candidates, not accuracy, and each newly named person
  adds a competitor that can steal a match.
- **Descriptors are only comparable within one request revision.** Store the
  revision; on a mismatch, ignore the row and recompute rather than comparing
  across revisions.
- **Same face across years** (a child) will not match, and should not be
  forced to.
- Open: cap on stored descriptors per person — unbounded is a linear scan per
  candidate. Probably "keep the N most recently confirmed", decided with the
  Phase 1 numbers.

## Closing the gap with Photos / Google Photos (Oct 2026, not started)
Their edge is mostly the system around the model, not just a bigger model:
clustering over the whole library, quality filtering, context. Apple's
person embeddings aren't exposed to apps.

Today: SFace, 2-point (eye) alignment, one embedding per crop, no quality
gate, nearest-neighbour with ceiling 0.637 + margin 0.06.

In order — each step measured before the next:
1. **Measure.** An eval from the user's own named faces: top-1 suggestion
   precision/recall, same/different distance histograms, errors split
   into detection, alignment and model. Without it every change is a guess.
2. **On-device, free** (0 MB, no network):
   - 5-point alignment (eyes, nose, mouth corners → ArcFace template,
     similarity transform) — what SFace was trained on.
   - Flip averaging: embed the mirrored crop too, average, renormalise.
   - Quality gate: `VNDetectFaceCaptureQualityRequest` + minimum face size.
     Low-quality faces are never prototypes and only get suggestions.
   - Cannot-link: two faces in one photo are two people.
   - Several prototypes per person (kNN vote), threshold per person.
   - Suggested groups: graph clustering with cannot-links, shown for
     naming, not stored (keeps the "no stored wrongness" non-goal).
3. **Bigger model, downloaded on first use** (ArcFace/AdaFace class,
   ~30–60 MB int8). Keeps the 33 MB budget. Blocker: licence — InsightFace
   weights are non-commercial, and MS1M-trained weights carry dataset risk.
   Needs commercially licensed weights first.
4. **Face file import — the server stays out of the app.** Designed in
   `MAC-PIPELINE.md` (Oct 24). The app reads
   one file of face labels; where it came from is not its concern (a
   script, a container, another photo app's export, typed by hand). The
   repo ships tools that make it from a bucket, outside the app's scope
   and size budget.

### Face file (`faces.json`, v1)
```json
{"version": 1,
 "photos": [{"key": "2024-06-01_9f3c…", "sha256": "…",
   "faces": [{"box": [0.41, 0.22, 0.12, 0.16], "person": "Alice"}]}]}
```
- **Photo**: `key` = bucket object key (stem, no prefix/extension), or
  `sha256` of the original's bytes. Either; key wins.
- **Box**: `[x, y, w, h]`, 0..1 of the upright image (EXIF applied),
  top-left origin — same space the app stores boxes in.
- **Person**: a name, matched to People the same way the profile CSV is;
  unknown names make a new person.
- Read tolerantly: unknown fields ignored, unknown photos skipped and
  counted.

### Import rules
- Box overlapping a found face (IoU ≥ 0.5, the existing rule) labels that
  face; no overlap adds the face with that box.
- Never overwrites a face already named in the app; a disagreement is
  listed, not applied.
- One explicit import = the tap the "nothing linked without a tap" rule
  asks for. A summary (applied / conflicts / unmatched) before commit.
- Imported names become reference faces for the on-device matcher, so a
  good file improves suggestions for later photos too.
- Hidden photos: tools can't see them (carriers are opaque), so their faces
  are never in a file; an entry naming one is ignored rather than revealing
  the match.

### Repo tools (`tools/faces/`, not in the app)
- Container: read the user's bucket with their own credentials, detect +
  embed (any model the user is licensed for), cluster, write `faces.json`
  with placeholder names (`person_07`) to rename, or names from labelled
  seeds.
- No server run by us, no account: the user's machine, the user's bucket.
  The licence question in step 3 becomes the user's choice of model, not
  something the app ships.

Rejected: **a central server we run.** It would hold biometric data for
every user's contacts (GDPR special category, BIPA), and it would need read
access to buckets the user owns. It also cuts against "your bucket, your
data". The file format gets the same accuracy without any of that.
