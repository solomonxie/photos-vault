# Components

## Tile  `lib/viewer/asset_grid.dart`

```
 ┌────────┐   square, sized outright (not AspectRatio — the long-press
 │        │   preview lays out unbounded and would throw)
 │      ◌ │   badges, bottom-right, one per corner claim:
 └────────┘     ♥ favourite · ☁ cloud-only · ▶ video · ◌ not yet backed up
 selecting ⇒ badges are replaced by ✓ / ○, never both at once
 placeholder ⇒ ▶ dark play glyph for video, grey ▣ for a photo
```

Image source, in order — the cache is a **fallback**, never the preference:

```
 live local file ─▶ OS library ─▶ app cached thumb ─▶ placeholder
 ✗ cache first: one stale absolute path (the container UUID changes on
   reinstall) blanks a tile whose real photo is sitting right there
```

## Day header

```
 Today · Yesterday · Sep 12, 2026      ← bold, above each day's tiles
```

## Date scrubber  `lib/viewer/date_scrubber.dart`

```
 ┆                    idle: not drawn at all
 ┆  ( Sep 2026 ) ▮    dragging: bubble names the month it will land on
 ┆                    fades in when the list moves, out ~1s after it stops
```

## Settings chrome  `lib/settings/settings_section.dart`

Card-less on purpose — rows sit on the page background, matching the sibling
podcasts app.

```
 Heading                                   Accent control ▾   ← at most one
 A small hint under it, footnote, muted.
 ┌───┐ Title                                            ─●
 │ ▣ │ subtitle — what tells near-duplicate rows apart
 └───┘ detail — this row's own stats
 ─────────────────────────────────────  ← hairline, inset under the title
 one-line stats footer, muted, tappable         ⟳ rides inline on it
 ══════════════════════════════════════  ← divider between sections

 [ ⟳ Sync Now ]      pill button: icon + label, filled
 [ − ] 3 at a time [ + ]    stepper: a value you nudge and watch
 Manual ▾            accent button, ▾ = opens a menu of values
```

Form fields, same chrome one step in — a fill, not an underline, because a
bare field is nearly invisible on this background:

```
 Access key ID            ← 13pt semibold; a column of five at row weight
 ┌───────────────────────────┐ reads as five headings
 │ AKIAIOSFODNN7EXAMPLE      │  SettingsField
 └───────────────────────────┘
 18 characters — usually 20.   ← helper, muted 11pt…
 Required                      ← …replaced by the field's own error, red

 Region                        SettingsPickerField — chosen, not typed
 ┌─────────────────────────┬─┐
 │ ap-guangzhou            │▾│ ← same box, chevron where the caret would be
 └─────────────────────────┴─┘

 ⊗ Access denied. (AccessDenied)   SettingsErrorLine — what stopped a save,
                                   under the fields it points at
```

## Chips

```
 ( sunset ⊗ )        tag — ⊗ removes
 ( ◯ Mei ⊗ )         person — avatar inline
 ( Nature ⊗ )        album
 ⊕ beside a section heading adds one
```

## Cards

```
 album   140×190   cover · name · N photos       hold ▸ Delete Album !
 person  100 wide  ◯ avatar · name · N photos
 group   a row, not a card: 📍 name … N ›
         ↑ a place is a word; most have no photo worth 140×190, and the
           section read as a row of grey pins
```
