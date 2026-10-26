# Faces from the Mac — offline analysis, imported into the app

Implements step 4 of `DESIGN.md` → "Closing the gap". Decided 2026-10-24.

## Problem
- On-device matching (SFace, eye-aligned, nearest-neighbour) misses the same
  person across photos often enough to be useless in practice.
- The phone is the wrong place for heavy work: size budget, battery, one
  photo at a time, no whole-library view.
- The Mac has the whole bucket (~24k stills, HEIF mostly), an M1 Pro, and
  no size budget.

## Goals
- Name most faces in the library in one sitting on the Mac, then one import
  on the phone.
- Best available accuracy; the model is the user's choice, never shipped.
- Rerunnable: new bucket uploads cost only their own photos.
- Phone matcher gets better too: imported names become its reference faces.

## Non-goals
- No server, no account, no upload anywhere but the user's own bucket reads.
- Not the zip-imported people's names (relation-tree): noisy, many faces
  per folder. Their archived photos are analysed (~19k stills) and grouped
  like any other; only library labels and names given on the phone seed.
- Re-runs: `phone` reads names given in the app back as labels; `--prev`
  keeps an earlier group's ID when most of its faces are still together.
- Videos (v1). Hidden photos (tools can't see them; see Import rules).
- Claude/vendor vision. Doesn't identify people by face, costly at 24k
  photos, and every family face would leave the Mac.

## Decisions

| Question | Decision |
|---|---|
| Model | InsightFace `buffalo_l`: RetinaFace (5 landmarks) + ArcFace R50, onnxruntime, CoreML EP. Non-commercial weights, personal use, Mac only |
| Input | Newest `app-data/` snapshot says which photos; their originals streamed, ≤ 16 on disk, deleted after. Thumbnails too small for group shots |
| Naming | In the app: every group exported with an ID, named on People → Faces to Name after previewing its faces. Mac review page optional, for naming ahead |
| Seeds | The user's own labels in the app (person ↔ open photo), from the snapshot. Photo-level, so each resolves to the face most like that person in their other photos. Zip-imported people ignored |
| App side | Imports `faces.json` (format in `DESIGN.md`); no new recognition code |

## Pipeline (`tools/faces/`, own venv, not in the app)

1. **List** open stills from the snapshot's `library.json` (creds from
   `.env.bucket`, read-only).
2. **Analyse** each new/changed object (key + ETag):
   - decode upright (`pillow-heif`, EXIF transpose), ≤ 2048 px long side;
   - detect → 5-point align → 512-d embedding, plus flip-averaged embedding;
   - per face: box (0..1 upright, top-left), det score, size px, blur,
     yaw (nose position between the eyes).
   - Cached in `tools/faces/work/faces.db` (gitignored).
3. **Quality gate**: face < 40 px, det score < 0.6 or turned away → never a
   cluster core; only attached to a cluster if close.
4. **Suggest** faces like a named person (top-3 mean cosine ≥ 0.42,
   margin 0.06). **Cluster** the rest: average linkage, cosine ≥ 0.45
   (0.40 mixed lookalikes; a split is one rename, a mix is many unticks);
   cannot-link (one face per photo per cluster); weak faces join only a
   group with ≥ 3 good faces, at ≥ 0.50 (junk faces look alike and piled
   onto small groups).
5. **Review page** (`python -m faces review`, localhost only):
   - clusters by size; each a grid of face crops (crops cached as JPEG);
   - name (autocomplete from the snapshot's People), naming two groups the
     same merges them, untick faces to split, "not a person / ignore",
     alt-click shows the photo (read from the bucket, not saved);
   - decisions saved in `faces.db` (`label(face_id, person, source)`),
     survive reruns: a rerun re-clusters only unlabelled faces and proposes
     joins to named people first ("these 37 look like Alice").
   - outliers: a person's references are their **main group** (largest set
     of their labelled faces linked at ≥ 0.40); labels outside it are not
     references and are listed under "Check these" (keep / remove).
6. **Export** `faces.json` v2, keyed by bucket key stem:
   ```json
   {"version": 2,
    "groups": [{"id": "r202610241954-0004", "faces": 47},
               {"id": "r202610241954-0001", "faces": 120, "suggest": "Ava"}],
    "photos": [{"key": "…", "faces": [
      {"box": [x, y, w, h], "person": "Me"},
      {"box": [x, y, w, h], "group": "r202610241954-0004"}]}]}
   ```
   A face has `person` or `group`. IDs carry the run time, never collide.
   `suggest` is a proposal: nothing is named until a tap in the app.

Measured cost: 0.2–1.7 photos/s on the M1 Pro (CPU-bound), ~4 h for 3.9k photos;
reruns minutes.

## App side
- Import `faces.json` per `DESIGN.md` → Import rules (summary before commit,
  never overwrites a name set in the app, conflicts listed).
- Photo match: record's original `destinationKey` stem = `key`. Unknown keys
  (hidden carriers, deleted records) skipped and counted together.
- Box match: RetinaFace and Vision boxes differ in extent, so IoU ≥ 0.5 is
  too strict. Rule: IoU ≥ 0.3 **or** imported box centre inside Vision box;
  closest wins. No match → add the face with the imported box.
- Imported faces are confirmed faces: face ↔ person links. The phone does
  no matching of its own (removed 25 Oct 2026; see `DESIGN.md`).
- Entry point: More → Developer Options → Import Faces File (Files picker), next to the
  existing CSV/zip imports.
- Group faces: stored as group membership, never named on import.
- People → Faces to Name: the imported groups, by size. Open a group →
  all faces ticked; untick wrong ones, view the photo; Name… (prefilled
  with `suggest`) links the ticked faces, the rest stay in the group. Not
  This Group, Delete Group. Same name on two groups = merged.
- Face crops: 3 photo decodes at once, newest tile first, none mid-fling.

## Prerequisites
- Review findings #3 and #4 (`docs/review/findings/05-analysis-faces.md`)
  poisoned the reference set; both already fixed on this branch.

## Risks
- Threshold is unknown until the first review; the page makes a wrong one
  cheap (merge/split), and only named faces leave the Mac.
- Children across years split into several clusters; merge by hand.
- InsightFace licence: fine for personal use; the repo ships only the tool,
  never weights (downloaded on first run).
- Decoded originals of private photos sit briefly in a temp dir; deleted
  after each photo, temp dir under `tools/faces/work/`.

## Tasks
- [x] T1 `tools/faces/`: venv, requirements, bucket lister + streaming
      downloader, `faces.db` schema.
- [x] T2 Analyse: decode, detect, align, embed, quality; resumable.
- [x] T3 Cluster with cannot-links + attach; rerun keeps labels.
- [x] T4 Review page (single-file HTML + tiny stdlib HTTP server).
- [x] T5 Export `faces.json`; dry-run stats (faces, people, photos).
- [x] T6 App: review findings #3/#4 (already fixed).
- [x] T7 App: `faces.json` parser + matcher (key, box rule) + summary sheet.
- [x] T8 App: commit path → confirmed faces.
- [x] T10 v2: groups in the file, People → Faces to Name naming.
- [ ] T9 Measure: phone suggestion precision before/after on held-out
      named faces.
