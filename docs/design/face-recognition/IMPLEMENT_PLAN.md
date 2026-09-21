# Face recognition — implementation plan

See `DESIGN.md` for why, `UIUX_DESIGN.md` for what it looks like.

## Phase 1: Prove the descriptor is worth building on
The whole decision rests on whether a *general* image descriptor separates
faces well enough to suggest a name. Measuring that costs one channel method
and a throwaway harness; building the feature first and finding out after
costs the feature. Nothing else starts until the numbers are in.

- [x] T1.1 Add `featurePrint(path, rect)` to the Vision channel — runs
      `VNGenerateImageFeaturePrintRequest` on the cropped region, returns the
      `Float32` vector, its element count and the request revision — see
      `ios/Runner/VisionAnalysisChannel.swift` — depends: none
- [x] T1.2 Dart side: `OnDeviceVisionService.featurePrint`, plus a
      `FaceDescriptor` value type and its distance function — mirrors
      `computeDistance` so matching is testable without a device — see
      `lib/photos/on_device_vision.dart` — depends: none
- [x] T1.3 Tight-crop geometry for descriptors — a second, smaller inset than
      `FaceCrops.padding`, so background doesn't dominate the descriptor — see
      `lib/photos/face_crops.dart` — depends: none
- [x] T1.4 **Dropped — the measurement can't precede the feature.** A
      same-person/different-person distribution needs labelled faces, and the
      only labels that exist are the ones the user makes by naming people.
      With nobody named there is nothing to measure. The feature seeds its
      own labels, so the gate moves to T5.0: ship with a provisional
      threshold, judge it on real suggestions, tune the constant.
- [x] T1.5 Superseded by T1.4's note — thresholds start provisional, in one
      named constant, and are recorded in `DESIGN.md` once tuned.

## Phase 2: Store and match
With thresholds known, the reference set and the matcher are pure data work —
no UI, fully unit-testable, and the piece everything visible sits on.

- [x] T2.1 `face_descriptor` table + migration in the analysis DB, with
      revision column and delete-with-person — see
      `lib/photos/ai_analysis_store.dart` — depends: none
- [x] T2.2 `FaceMatcher`: nearest neighbour over stored descriptors, ceiling
      and margin gates, returns a person or nothing — see
      `lib/photos/face_matcher.dart` — depends: none
- [x] T2.3 Write a descriptor whenever a face is linked to a person — the one
      place all three surfaces already funnel through — see
      `lib/viewer/person_picker_sheet.dart` (`nameFace`) — depends: T2.1
- [x] T2.4 Per-person descriptor cap and eviction — keeps the scan bounded —
      see `lib/photos/ai_analysis_store.dart` — depends: T2.1

## Phase 3: Match during analysis
The matcher has to be fed. This rides the analyze queue rather than a pass of
its own: it is the same shape of work, already paced and pausable, and a
second background loop would fight it for the battery.

- [x] T3.1 New `AnalyzeStep.matchFaces` — per photo with faces and no named
      person, descriptor per face, match, store the suggestion — see
      `lib/photos/analyze_queue.dart` — depends: T2.2, T2.3
- [x] T3.2 Persist suggestions per face so they survive a restart and the
      queue stays derivable — see `lib/photos/ai_analysis_store.dart` —
      depends: T2.1
- [x] T3.3 Re-match on new evidence: naming somebody re-runs the match for
      faces that had no suggestion — bounded, newest first — see
      `lib/photos/analyze_queue.dart` — depends: T3.1

## Phase 4: Show it
Last, because a suggestion with nothing behind it is a lie. All three
surfaces read the same stored suggestion, so they land together.

- [x] T4.1 `UnnamedFace` carries its suggestion; `findUnnamedFaces` reads it —
      see `lib/photos/unnamed_faces.dart` — depends: T3.2
- [x] T4.2 Suggested card on the home People row, tap → picker with the guess
      pinned — see `UIUX_DESIGN.md` → Home People row — depends: T4.1
- [x] T4.3 Suggested row + inline accept + undo toast on the People page —
      see `UIUX_DESIGN.md` → People page — depends: T4.1
- [x] T4.4 Suggested labels under the detail screen's face crops — see
      `UIUX_DESIGN.md` → Detail screen — depends: T4.1
- [x] T4.5 Strings in `app_en.arb` / `app_zh.arb` — see `UIUX_DESIGN.md` →
      Copy — depends: none
- [x] T4.6 Fold the shipped mocks into `../uiux/people.md` and
      `../uiux/detail.md`, delete this doc's duplicates — depends: T4.2, T4.3,
      T4.4

## Phase 5: Close out
- [x] T4.7 Forget a person's descriptors from the *profile* screen's delete
      too — today only the People list's delete calls `forget`, so a person
      deleted from their profile leaves descriptors that can still win a
      match (they show as "Who's this?", never under the dead name) — see
      `lib/viewer/person_profile_screen.dart` — depends: T4.3

- [x] T5.0 Superseded — SFace ships with its authors' published
      same-identity threshold (0.363 similarity = 0.637 distance), so there
      is a real number rather than one to tune blind. The old invented
      ceilings are gone.
- [ ] T6.1 Confirm the model actually loads on device — it falls back to the
      image descriptor silently if `SFace.mlmodelc` isn't found, which looks
      like "no improvement" rather than an error — depends: none
- [ ] T5.0-old Tune the threshold on real suggestions and record the number in
      `DESIGN.md` → Decision — the gate T1.4 was meant to be — depends: T4.2
- [x] T5.1 One test pass + release build + install per `CLAUDE.md` —
      depends: T4.2, T4.3, T4.4, T4.5
- [x] T5.2 Update `../DESIGN.md` → Person identity: clustering was the stretch
      goal, this is what shipped — depends: T5.1
