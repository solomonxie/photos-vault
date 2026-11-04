# Footprints v2 — interface

Why: `DESIGN.md`. Platform rules: `uiux` skill, mobile + media-library.

## Library section (1, 2)

```
FOOTPRINTS
┌───────────────────────────────┐
│ [map snapshot, every pin]     │
│ 14 countries · 63 cities      │
└───────────────────────────────┘
│ 📍 Places            63 › │
│ ⤳ Travel Plans        4 › │
│ ⟲ On This Day: Kyoto, 2017 › │   ← only when a visit falls on today
```

## Places (3, 4, 5)

```
┌───────────────────────────────┐
│           full map            │
│    ●     ●   ●                │
├──────────── ═══ ──────────────┤  drag: peek · half · full
│ [Search places]   [↕ Sort]    │
│ 🇯🇵 Japan                  12 │
│   [img] Kyoto       ★4.5  340 │
│   [img] Osaka              88 │
│   Show 4 More ⌄               │
└───────────────────────────────┘
```
- Sort menu: Most Photos · Recent Visit · A–Z; toggle "With Impressions".
- Tap a pin on the map → its row scrolls into view, highlighted.

## Place page (6, 7, 8, 9)

```
┌───────────────────────────────┐
│ [cover photo]                 │
│ Kyoto                         │
├───────────────────────────────┤
│ [map card]                    │
│ Description…                  │
│ VISITS                        │
│ Apr 3 – 5, 2017      42 › │
│ Oct 2019             12 › │
│ PINS  (swipe: Move · Delete)  │
│ IMPRESSIONS (swipe: Delete)   │
│ TRAVEL PLANS                  │
│ PHOTOS  See All 340 ›         │
└───────────────────────────────┘
```
- Visit = a run of days with photos there, gaps > 2 days split it.

## Impressions (10, 11, 12)
No list of their own on Library: read on each place page.
Reading view: place, day, text.

## Impression
Text only, attached to one place or pin, with the day it's about. No
title, rating, tags, people or photos (older ones keep theirs, unshown).

```
New Impression                    Save
📍 Gion                  Apr 3, 2017 ›
┌───────────────────────────────┐
│ What happened, what it was…   │
└───────────────────────────────┘
```

## Travel plans (13, 3: draft)

Route page: `Day 2 · Apr 4` divider before each day's first stop. Under a
stop, its photos fold: taken near it from its arrival (else the plan's
start) to the next dated stop (else the plan's end, else a week on).
A leg shows only when its mode or note is set; no warnings here.
```
(1) Surrey
    Canada
    ▢ 12 photos here ⌄        ← tap: strip; tap a photo: the group
    🚆 Train · Fuji on the right
(2) Banff
```

Editor: no photos or people. Stops are one inset card.
```
STOPS
┌──────────────────────────────────────┐
│ (1) Surrey              Apr 3    ≡   │  date: tap; unset "Add date"
│     Add a note                       │
│     ↓ How you got to Banff ›         │  set: "🚆 Train to Banff ›"
├──────────────────────────────────────┤
│ + Add Stop                           │
└──────────────────────────────────────┘
Swipe a stop left to delete it; drag ≡ to reorder.
[            Delete Route            ]
```
Mode sheet: every mode but Other, plus Clear when one is set.
- Plans list `+` menu: New Plan · Draft from Photos.

## Throughout (15, 16)
- Empty states: one line + one button (`Add a Place`, `Write an Impression`,
  `New Travel Plan`).
- Delete → toast `Deleted · Undo` for 4 s, with haptic.

## Extension
Place page: description · Pins · **Impressions** (card: place, date,
text) · **Travel Plans** (title, dates, stops) · Photos.

## Deviations
None.
