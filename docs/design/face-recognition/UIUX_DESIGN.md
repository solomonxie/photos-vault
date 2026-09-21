# Face recognition — UI/UX

Drawings only, ~60 cols. Glyphs per the `uiux` skill and
`../uiux/README.md`. Reasoning lives in `DESIGN.md`.

Three existing surfaces gain a suggestion; no new screen. When this ships,
these mocks fold into `../uiux/people.md` and `../uiux/detail.md`.

## Screen map

```
 LibraryScreen ─ People row ──▶ PeopleScreen
   │  ◯ Nina?  ← suggested card        ◯ Nina?  [✓] ›  ← suggested row
   │     tap ⇒ picker, suggestion first    ✓ ⇒ accept in place
   │
   └─ tile ──▶ DetailScreen ─ People section
                 ◯ Nina?  ← suggested face chip
```

## Drawings

Shipped, so the mocks moved to where the rest of the app's are — a second
copy is a stale copy:

- home People row and the People page → `../uiux/people.md`
- the detail screen's face row → `../uiux/detail.md`
- the analyze queue's matching step → `../uiux/queue.md`

## States

```
 no descriptors yet   every face reads "Who's this?"   ← nobody named yet
 below threshold      "Who's this?"                    ← a guess it won't make
 two people close     "Who's this?"                    ← margin gate, no coin-flip
 not iOS              "Who's this?"                    ← no Vision, no suggestions
 accepted             row/card leaves the list, toast with Undo
 rejected             picks somebody else ⇒ that face becomes their reference
```

## Copy
| Key | String |
|---|---|
| `peopleSuggestedFace` | `{name}?` |
| `peopleSuggestedBadge` | Suggested |
| `peopleSuggestionAccepted` | Added to {name} |
| `actionUndo` | Undo |

## Notes
- No settings toggle. It costs nothing, sends nothing, and asserts nothing —
  a switch would be a question with one sensible answer.
- No confidence percentage. A number invites arguing with it; the app either
  has a guess worth offering or it doesn't.
- Deviation from `uiux/mobile.md` "picker unfolds in place": the person
  picker stays a sheet, as it is today — it searches a corpus rather than a
  short fixed list, which that rule exempts.
