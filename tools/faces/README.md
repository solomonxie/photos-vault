# Faces from the Mac

Names faces across the library on the Mac, for the app to import
(More → Developer Options → Import Faces File). Design: `docs/design/face-recognition/MAC-PIPELINE.md`.

## Setup
```
/opt/homebrew/bin/python3.12 -m venv tools/faces/venv
tools/faces/venv/bin/pip install -r tools/faces/requirements.txt
mkdir -p tools/faces/work/models && cd tools/faces/work/models
curl -LO https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip
unzip buffalo_l.zip det_10g.onnx w600k_r50.onnx && rm buffalo_l.zip
```
Bucket credentials come from `.env.bucket`. The bucket is only read.
InsightFace weights are non-commercial: personal use, never shipped.

## Run
```
py=tools/faces/venv/bin/python
$py tools/faces/run.py analyse [--refresh] [--limit N]   # resumable
$py tools/faces/run.py phone --db ai_analysis.db --people people.db   # copies off the phone
$py tools/faces/run.py cluster
$py tools/faces/run.py review                            # http://127.0.0.1:8765
$py tools/faces/run.py export --out faces.json --prev <last imported faces.json>
```
- `analyse`: stills in the newest app-data snapshot, archived (zip-imported)
  included; hidden, binned and videos left out. 16 originals on disk at most,
  each deleted once read. `--refresh` re-reads the snapshot.
- `phone`: faces named on the phone become labels (matched by box), so
  their other faces are proposed under the same name.
- `cluster`: your labels in the app seed people (zip-imported people
  ignored); faces like them become suggestions, the rest are grouped.
  Rerun after each review session; review labels are kept.
- `review` (optional): name groups on the Mac first. Same name twice =
  merge; untick wrong faces; alt-click for the photo; "Check these" lists
  labels that don't fit the person.
- `export`: `faces.json` v2. Named faces keep their name; every other
  grouped face carries a group ID, named in the app (People → Faces to Name).
  Groups that look like a named person carry a proposed name. `--prev`: a
  group mostly made of an earlier group's faces keeps its ID, so a re-import
  adds to it.

`work/` (gitignored) holds `faces.db`, face crops and the models.
