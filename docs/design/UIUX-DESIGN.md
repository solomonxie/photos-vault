# UI/UX Design Guideline

This app's UI/UX decisions and the reasoning behind each. Companion to
[DESIGN.md](DESIGN.md) (architecture) — this one covers what the user sees.

Section headings mirror the personal `my-mobile-design-guideline.md` under the
`uiux` skill, so anything settled here can be folded back into it.


## Overall style

Apple minimalist style, modern, simple, intuitive, clear...

Design against **real screenshots of the app you're imitating**, not from memory. Every IA correction below came from holding the build next to the real thing.

Default section styling for any settings-ish page — **no cards**. Rows sit
directly on the page background, separated by inset hairlines. A card
inside an already-dark page is one more edge to get wrong, and the seam it
leaves is the single most visible dark-mode bug (see Theme below).

Two heading tiers, and only two:
- **Primary** (the page's subject — the thing being listed): 20px, weight 700, white.
- **Secondary** (settings that govern it): 12px, weight 600, letter-spacing 0.5, UPPERCASE, muted.
- Heading row carries **at most one** right-aligned accent control (`Manual Only ▾`, `⊕`) — a text link or a bare glyph, never a filled button.
- Hint under the heading: 11px muted, ~1.35 line-height. One short paragraph: what it's for, plus any privacy/cost caveat.
- Row: 15px/w600 title, 11px muted subtitle, 12px muted detail line.
- Container rows lead with a 44pt rounded square (radius 6) filled with an accent *gradient*, white glyph — flat fill reads dead at that size.
- Hairline between rows is inset to where the title starts (56 = 44 tile + 12 gap), so it reads as a list, not a table.
- Stats: a compact one-line footer under the list, never its own row or section. In-progress state rides inline on it.
- Sections are separated by a full-width hairline with 24px above and below.

```
Cloud Buckets                                        ⊕   ← 20 · 700 · white
Photos upload to storage you own. Credentials stay       (one control, right)
on this device and go straight to the bucket.        ← hint: 11 muted
┌────┐  slmx-archives2                              ⋯
│ ☁  │  s3://slmx-archives2/photos/                      ← 15/w600 · 11 muted
└────┘  ca-central-1                                     ← 12 muted detail
  44     ────────────────────────────────────────────    ← hairline, inset to 56
┌────┐  backup-eu                                   ⋯
│ ☁  │  s3://backup-eu/photos/
└────┘  eu-west-1
1 bucket · 56 of 57 photos backed up          ⟳ Syncing…  ← stats, 12 muted;
Sync queue: 12 pending · 2 at a time  ›                     progress rides inline
────────────────────────────────────────────────────────  ← 24px · hairline · 24px
SYNC FREQUENCY                          Manual Only ▾   ← 12 · 600 · UPPERCASE
Checked opportunistically while the app is open —
there's no background-sync permission yet.
Last synced Sep 15 4:26 PM
Sync Now                                               ← accent link, left-aligned,
                                                         disabled (not hidden) with
                                                         no bucket configured
```

Be honest in copy about limitations. If background sync isn't registered with the OS, say "only while the app is open" rather than implying otherwise.


## Languages

Support multi-languages since day1.

Every user-facing string goes through the localization layer from the first screen — retrofitting means re-touching every hardcoded string later.

Decode network payloads explicitly as UTF-8. Don't trust `Content-Type` charset sniffing: S3's XML is UTF-8 but omits the charset param, so default sniffing falls back to latin-1 and turns CJK filenames into mojibake.

```
bytes on the wire    →  decoded as latin-1  →  "ä¸­æ..."   ✗ mojibake
(UTF-8, no charset      decoded as UTF-8    →  "中文.mp3"   ✓
 param in the header)
```


## Navigation & information architecture

- If the content is one library, it's **one scrollable page, not tabs**. Stacked sections (grid → collections → utilities) beat a tab bar.
- **Fill the screen the user is on first.** A first scan of a big library reads it *newest first*, draws the first page straight away, and lets the rest arrive off-screen behind it. Reading in library order would put 2011 on screen and then shove it around for a minute; waiting for the whole scan would show nothing at all for that minute.
- **Growing a list must not move what's being read.** In a bottom-anchored grid every older photo that arrives lands *above* the viewport and pushes the current one down the page by exactly its own height. Holding a scroll offset therefore drifts the content under the reader's thumb on every batch. Hold a *photo* instead — find it again by when it was taken, which doesn't change when the list grows around it.
- **Open where the user's attention already is.** A library page opens on the *newest* photos with the sections just below the fold — never at the top of a decade of history. The photo someone wants is almost always the one they just took.
- Don't invent a tab for something that is a section.
- Don't invent a page for something that is a menu. A page whose only job is holding two links should be deleted.
- Size the surface to the size of the decision:
  - **picking a value never leaves the page** — tag, gender, location, school, employer, person all open a searchable drop-down sheet above the current page
  - a full page push is for *browsing or editing an entity*, never for choosing one value out of a list
  - a handful of actions on one object → `…` menu
- Anything that names another entity must be tappable and open that entity. No dead-end references.
- Label actions by what they do: a `+` that opens a browse screen should say "More".
- Name things as the user thinks of them: "Places Lived" not "Movement History"; "Private Cloud" not "Cloud Backups".

```
DO — one scrollable page              DON'T — a tab per section
┌─────────────────────┐               ┌─────────────────────┐
│ Library         🔍  │               │ Library         🔍  │
│ ▦ ▦ ▦ ▦   Yesterday │               │ ▦ ▦ ▦ ▦             │
│ ▦ ▦ ▦ ▦             │               │ ▦ ▦ ▦ ▦             │
│ Collections         │               │                     │
│   Albums · People   │               │                     │
│   Places · Events   │               ├──────────┬──────────┤
│ Utilities           │               │ Library  │ Collect… │ ← a tab standing in
│   Favorites · …     │               └──────────┴──────────┘   for a section
└─────────────────────┘
```

Surface ladder — match the surface to the weight of the decision:

```
pick any value           ─▶  searchable drop-down sheet, ≤55% height
  (tag, location,            ┌──────────────────────────┐
   school, person)           │           ▬▬             │
                             │        Location          │
                             │  🔍 mel                  │
                             │  ⊕ Use "mel"             │
                             │  Melbourne            ✓  │
                             │  Melrose                 │
                             │  ⊗ No Location           │  ← clear row, only when set
                             └──────────────────────────┘
browse / edit an entity  ─▶  full page push
act on one object        ─▶  ⋯ menu
confirm something risky  ─▶  alert dialog, Cancel LAST
```


## UI Components

### Theme
Support light/dark theme by default, and choose theme automatically by system settings.

Dark-theme pitfalls:
- Page background: a dark charcoal (`0xFF1C1C1E`), never pure black. Cards one step lighter (`0xFF2C2C2E`).
- Grouped list sections default to `systemGroupedBackground` = pure black in dark mode — harsher than the page, and it renders as a visible seam/void around the card. Override background + decoration **everywhere**, consistently; one missed screen is obvious.
- Bare text fields are nearly invisible on dark. Use filled form rows/cards.

```
✗ un-overridden section            ✓ overridden
  page   #1C1C1E                     page   #1C1C1E
  ░░░░░░░░░░░░░░░░░░                 ░░░░░░░░░░░░░░░░░░
  ░ ███████████████ ░  ← #000000     ░ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ░  ← #2C2C2E card,
  ░ █ card        █ ░    seam:       ░ ▓ card        ▓ ░    one step LIGHTER
  ░ ███████████████ ░    a void      ░ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ░    than the page
  ░░░░░░░░░░░░░░░░░░                 ░░░░░░░░░░░░░░░░░░
```


### Pop up window

if something / some options aren't many, don't jump to another page, but use propor sized dropdown menu or pop up window instead.

- Put every per-connection/per-object action in one `…` menu: e.g. sync frequency picker, "Last synced: …", Sync Now, Sync Queue, Delete Connection.
- Transient status lists (a queue) belong in a sheet, not a pushed page.
- Alert dialogs stack 3+ actions in list order — put Cancel **last**, not first.

One `⋯` menu holds the whole object's surface area:

```
  ‹ Back        slmx-archives2                  ⋯
                                                │
        ┌───────────────────────────────────────┴──┐
        │ ✓ Manual (no auto sync)                  │  frequency: a checked list,
        │   Every 15 minutes                       │  not a sub-page
        │   Every hour                             │
        │   Every 6 hours                          │
        │   Every day                              │
        ├──────────────────────────────────────────┤
        │   Last synced: 9 hours ago               │  status, not an action
        ├──────────────────────────────────────────┤
        │   Sync Now                               │  always available
        │   Sync Queue                         ☰   │  opens a sheet
        ├──────────────────────────────────────────┤
        │   Delete Connection                  🗑   │  destructive, last
        └──────────────────────────────────────────┘
```


### Diagrams

Trend graphs: by semantic meaning, can prefer stacked line graph, with avg or some baselines (dotted). and have vertical axis to denote number levels. Graph should be horizontally scrollable. and have list icons, click each item, can hide/show that in the diagram/graph.

Relationship/network graphs: wrap in a pinch-zoom + pan viewport; cluster the primary group (e.g. family) and colour-code the rest by type.

```
 $
 │      ╭─╮                          ← series, stacked
 │  ╭───╯ ╰──╮        ╭───╮
 │──┴────────┴────────┴───┴──  avg   ← dotted baseline
 │
 └──────────────────────────────▶    ← horizontally scrollable
    Jan  Feb  Mar  Apr  May

 ● Groceries   ● Rent   ○ Fuel       ← tap a legend item to hide/show it
                          ↑ hidden
```


### Buttons

Sometimes text link style look better than big button, depends on the usage.

```
✓ + Add Cloud Bucket          ✗ ┏━━━━━━━━━━━━━━━━━━━┓
  (accent text link)             ┃  ADD CLOUD BUCKET ┃
                                 ┗━━━━━━━━━━━━━━━━━━━┛
```


### Grids and tiles

- Day-grouped square grid under bold date headers ("Today" / "Yesterday" / localized date).
- **Oldest at the top, newest at the bottom**, and the page *opens* scrolled to the bottom. Time runs down the page, so "further up" means "further back" — and the newest day needs no scrolling at all.
- That bottom-of-the-grid position is the page's **home anchor**: tapping anywhere on the header — the status bar strip *and* the navigation bar under it, not just the title — returns to it, and tapping again from there goes to the very top (the oldest day, and the search field). A tap target that's only the title's own glyphs is a target you have to aim at. Scrolling to the oldest photo is a thing you can ask for, never the thing you land on.
- Past a couple of screens of content, a **fading date scrubber** rides the right edge: it appears while the grid moves, fades out ~1.4s after it stops, and while dragged shows the month it's landing on. It's the only way to cross years without flinging — so it **shows itself once, unprompted, on arrival** and lingers a beat longer that first time. A control that only ever appears *after* you've started thumbing is a control nobody discovers.
- Its track is **a third of the screen, centred**, not edge to edge. A handle parked against the top or bottom reads as chrome and goes unnoticed; one in the middle is where the eye already is. Track length is only the gearing — a whole decade crossed in half a screen is *less* thumb travel, not more.
- Large-title nav bar with a search field above it.
- **3 tiles per row**, 8px gutters, 8px corner radius. Four-up at 2px gutters packs more in but reads as a contact sheet; at three the photo is the subject.
- Badge only the **exceptional** state. A not-yet-synced dot, nothing at all when it's fine — a healthy library should read clean, not carry a checkmark on every tile.
- **Hold a tile to start selecting** (Photos' own gesture) — one gesture, one meaning. Screens with no batch actions keep the long-press context menu instead.
- Multi-select reuses the same tile with a checkmark overlay rather than a separate mode/screen; the batch actions live in a bottom bar that only exists while selecting.
- Batch delete is the one destructive batch action, and it asks once for the whole selection, **naming the count**: "Delete 40 photos?" is a different decision from "Delete this photo?", and by the time the sheet is up the selection has usually scrolled out of sight. A prompt per photo isn't a safeguard, it's a wall to click through.
- Every other batch edit is additive or a single-field set (tag, place, event, date shift).
- Adjusting the date on a multi-selection **shifts** every photo by the same delta rather than stamping them all identically, so a burst keeps its spacing.
- **A video is a tile with a picture on it**, same as a photo — its poster frame, with a small camera badge. A black square and a play glyph says "a video" and nothing about *which* video, which is the only question a grid answers. The play-glyph tile stays as the fallback for a file with no frame to show.
- Tile image source order: live local file → OS library thumbnail → app's own cached thumbnail → placeholder. The cache is a *fallback*; preferring it means one stale path blanks a tile whose real photo is right there.

```
        ▲ scroll up = further back in time
Library                 ← large title
🔍 Search
Yesterday               ← bold day header
┌────────┬────────┬────────┐
│        │        │        │   3 per row · 8px gutters · r8
│        │        │      ◌ │  ← ONLY the not-yet-synced tile is badged
└────────┴────────┴────────┘     (dotted ring, bottom-right)
Jul 31, 2026
┌────────┬────────┐
│      ☁ │     ✓  │  ← ☁ = cloud-only (local original freed)
└────────┴────────┘     ✓ = selection overlay, same tile, no separate screen

        ▼ the page OPENS here: newest day resting on the bottom edge,
          Collections just below the fold

date scrubber — only while the grid is moving:

┌─────────────────────┐        ┌─────────────────────┐
│ ▦ ▦ ▦               │        │ ▦ ▦ ▦               │
│ ▦ ▦ ▦          ┈┈┈  │        │ ▦ ▦ ▦          ┈┈┈  │ ← track: half the
│ ▦ ▦ ▦            ▲  │ ←idle  │ ▦ ▦ ▦   ┌────────┐▲ │   screen, centred
│ ▦ ▦ ▦            ▼  │  fades │ ▦ ▦ ▦   │Mar 2019│▼ │ ←dragging: shows
│ ▦ ▦ ▦          ┈┈┈  │  out   │ ▦ ▦ ▦   └────────┘   │   where it lands
└─────────────────────┘        └─────────────────────┘

hold a tile ⇒ selection mode, and a bar appears for the batch:
┌──────────────────────────────────────────┐
│ 2 Selected                          Done │
│   ⊕ Add Tag  ⌖ Set Place  ▤ Set Event  ◷ Adjust Date │
└──────────────────────────────────────────┘
```

Tile image source — the cache is a fallback, never the preference:

```
live local file  ──found──▶  draw it
      │ missing
      ▼
OS library thumb ──found──▶  draw it
      │ missing / cloud-only
      ▼
app cached thumb ──found──▶  draw it
      │ missing
      ▼
   placeholder

✗ preferring the cache first = one stale path blanks a tile
  whose real photo is sitting right there (container UUIDs
  change on reinstall, so cached absolute paths go stale)
```


### Lists and rows

- A row representing a container (folder, connection, album) carries a one-line stats footer beneath it: `361 episodes synced · 12.14 GB`.
- Stats come from already-collected local metadata, not a live rescan on open.
- Destructive actions live in the item's own menu, never as a second tap target beside the disclosure chevron.
- Once a flat list has categories, group it into typed subsections with their own headers.

```
📁  bible-audio                                    ›
─────────────────────────────────────────────────────
361 episodes synced · 12.14 GB     ← one-line footer, muted, from local
                                     metadata — NOT a live rescan on open

✗  📁  bible-audio                            🗑   ›
                                               ↑ second tap target next to
                                                 the chevron = mis-taps.
                                                 Delete belongs in ⋯ .
```


### Detail viewer (media)

- Full-screen swipeable pager, dark background, "Done" plus a bottom action bar.
- **A photo opens by growing out of the middle, not sliding in from the edge.** A sideways push reads as "somewhere else in the app"; a photo isn't somewhere else, it's the thing you just tapped, bigger. Start the scale close to full size — a big zoom reads as a transition of its own rather than as the photo opening.
- **Dismissal is measured in overscroll, not finger travel.** Bouncing physics hand back roughly a third of the drag once past the edge, so a threshold that sounds small (80pt) costs a haul halfway down the screen. Pick the number by pulling, not by reading it.
- Info panel lives **below** the image — scroll or drag down to reach it; past a threshold that same drag dismisses back to the grid. An info button in the bottom bar scrolls to the same place.
- Pinch to zoom, double-tap to zoom ~3x centred on the tap point, double-tap again to reset. Enable panning **only while zoomed**, or it fights the pull-down-to-dismiss gesture.
- Info panel is a grouped rounded card with inset dividers, not a flat full-bleed divided list.
  - Header: date/time, filename as a muted second line.
  - Free-text fields (caption, location) as their own rounded cards, not bare text on the background.
  - **Location fills itself in from the photo's own GPS tag** — the camera already recorded where it was, so asking the user to type "Melbourne" a thousand times is asking them to re-enter data they already gave you. Reverse-geocode through the OS geocoder, on view and one photo at a time (it's rate-limited per app, so a background sweep of a decade would spend the whole budget on photos nobody is looking at), and only ever into an *empty* field — a place someone typed is theirs.
  - Every row that can be edited is tappable in place (date/time sheet, pickers, chips).
  - **Let the platform tell you what changed; don't go looking.** iOS's photo-library change observer hands over the exact ids that were inserted, altered and removed, so staying in step with Photos costs work proportional to *what changed* — a hundred-thousand-photo library that gained one photo is one id. A background crawl over the library would be the right answer only if the platform offered nothing; here it reads every photo to discover that almost none of them moved, and bills the battery for the privilege. The crawl's one advantage, not blocking, is also available for free: the notification path has nothing to block on.
  - **Re-read the OS library every time the app comes back to the foreground.** This app is a second window onto the same photos, not a copy of them: a photo hearted, deleted or taken in Photos while you were over there has to be right when you return. Scanning only at cold start means the two disagree for as long as the app stays alive — and the user's mental model is that they're looking at one library. A scan that only *changed* things still has to redraw; "nothing was added" isn't "nothing happened".
  - **Deleting here deletes the photo, not this app's note about it.** A camera-roll asset goes from the OS library as well, into *its* 30-day bin — and if the OS asks for its own confirmation and the user declines, nothing is deleted anywhere. Deletion coming the other way is not symmetrical: a photo deleted in Photos that this app has already backed up stays in the library as a cloud-only item, because the backup outliving the phone is the entire point.
  - **The backed-up copy is purged only when the app's own bin is emptied.** Anything short of that must leave the bucket alone, or "Recently Deleted" is a lie — there'd be nothing left to restore from. If the purge fails (offline, credentials rotated), keep the record: dropping it locally orphans objects with nothing left pointing at them.
  - **An edit that belongs to the photo goes back to the OS photo library too.** This app isn't a second library: hearting a photo here and finding it un-hearted in Photos means keeping two mental copies of one collection. Favourite and creation date are writable through PhotoKit and are mirrored both ways — a heart added in Photos shows up here on the next scan. Caption, description and tags have no public write API on iOS, so those stay the app's own; say so rather than letting the user assume they synced.
  - **The keyboard must not relayout the page under it.** A full-bleed media page sized to the viewport shrinks when the scaffold resizes, which shoves the photo and everything below it upward the moment a caption takes focus. Freeze the layout and give the scrolling panel keyboard-height padding instead, so the focused field scrolls clear on its own.
- "Edit" sits top-right in the nav bar and opens a menu: Crop, Rotate, AI Touch Up.
  - Crop and rotate are local and instant; rotate is a **full 360° dial** you spin, not four preset buttons.
  - AI Touch Up asks for a prompt, then runs in the background — the Edit button becomes "AI working…" and the library shows the same line, so leaving the photo doesn't cancel anything.
  - Every edit **lands as a new photo** carrying the original's date, description, tags, place, event and people. Editing in place would silently overwrite what's already backed up under that key.
- **Video gets a real transport, not just tap-to-play**: a persistent bar under the frame with play/pause, elapsed and remaining time, a draggable timeline and mute. Dragging it seeks *live* — the frame under your thumb is the frame you see — and playback pauses for the drag, then resumes if it was running.
- **A Live Photo plays while held**, like Photos: press and hold the still, release to stop. The paired video is fetched on the first hold, never on open — pre-loading it would pull a video file (and maybe an iCloud download) for every photo swiped past. A small LIVE badge marks the photo both in the grid and in the viewer.
- Export/share: offer the original always; offer re-encoded formats only where you actually have an encoder, and say why when you don't.

```
   ▲  drag down past threshold  ⇒  dismiss back to the grid
   │
   Done                                              Edit   ← Edit top-right
   ───────────────────────────────────────────────────────
                        [  photo  ]        pinch / double-tap 3x at tap point
                                           pan ONLY while zoomed, or it fights
                                           the pull-down-to-dismiss drag
   share    favorite    info    adjust    trash
                          └── scrolls down to the panel ──┐
   ───────────────────────────────────────────────────────│
   │  scroll / drag up                            ◀───────┘
   ▼
   Sat · Sep 12, 2026 · 4:13 PM                           ← date/time header
   IMG_4934                                               ← filename, muted
   ╭───────────────────────────────────────────╮
   │ Location                      No Location │  grouped card,
   ├───────────────────────────────────────────┤  inset dividers —
   │ Dimensions                      4288×2848 │  NOT a flat full-bleed
   ├───────────────────────────────────────────┤  divided list
   │ Backup status                     Pending │
   ╰───────────────────────────────────────────╯
   ╭───────────────────────────────────────────╮
   │ Add a description…                        │  free text = its own card,
   ╰───────────────────────────────────────────╯  not bare text on the bg
```


### Pickers and inputs

- Any value that is free text but repeats across records (location, event, tag, school, employer, organization) gets a **fuzzy search-or-create picker**: typing filters existing values across all records, and the same field creates a new one. No separate "create" button, no separate mode.
- That picker is a **drop-down sheet over the current page**, never a page push — picking a value shouldn't cost a navigation. It carries the field name, a checkmark on the current value, and a clear row when one is set.
- **Size it to what's in it**, capped at 55% of the screen and floored at something worth opening. Choosing between three events should be a small pop-up; the same half-screen slab every time reads as a page and buries the photo behind it.
- Passcode entry: tap-only numeric keypad with dot indicators, not a system keyboard. Auto-submit on the final digit when there's nothing left to disambiguate.
- Credential/technical fields: disable autocorrect and smart punctuation. Smart quotes and dashes silently corrupt pasted keys and produce "wrong credentials" errors that aren't.
- Validate destructively-wrong input before saving, with non-blocking hints (e.g. "20 characters — AWS keys are usually 20") to catch bad pastes.
- Keep a draft of any failed or abandoned form so nothing is retyped.
- Surface the provider's own error code verbatim alongside your friendly message — each code points at a different field to fix.
- Confirm destructive actions, naming the specific thing being removed.

Search-or-create — one field does both, no mode switch:

```
┌──────────────────────────────────┐
│ 🔍 seat|                         │  ← typing filters existing values
├──────────────────────────────────┤     across ALL records…
│ Seattle                          │
│ Seatac Airport                   │
├──────────────────────────────────┤
│ Use "seat"                       │  ← …and the same field creates.
└──────────────────────────────────┘     No separate "+ Create" button.
```

Passcode — tap-only, no system keyboard:

```
        ● ● ○ ○          ← dot indicators, not a text field
       ┌───┬───┬───┐
       │ 1 │ 2 │ 3 │
       ├───┼───┼───┤
       │ 4 │ 5 │ 6 │
       ├───┼───┼───┤
       │ 7 │ 8 │ 9 │
       └───┼───┼───┘
           │ 0 │            auto-submits on the 4th digit when there's
           └───┘            nothing left to disambiguate

         Cancel             ← LAST. Dialogs stack 3+ actions in list order.
```

Credential fields — the failure mode is invisible:

```
typed/pasted:   AKIA...20 chars
iOS "helpfully" applies smart quotes / autocorrect
stored:         AKIA…19 chars + a curly quote
result:         403 SignatureDoesNotMatch  ← looks like bad credentials,
                                             is actually bad text input
fix:  autocorrect off · smart quotes off · smart dashes off
      + non-blocking hint:  "19 characters — AWS keys are usually 20"
```


### Empty state & demo data

- Ship bundled demo data so the app is explorable before anything is configured ("Try with Demo Photos"). Nothing to fetch, no account, no connection.
- **Whatever adds sample data must also take it away**, on a page of its own with both verbs spelled out and what each touches. A single "Reset Demo Data" row was one verb doing two jobs — topping the demo content up *and* being the only way to get it back — while nothing offered to remove it. Sample photos are easy to add to a real library by accident and should never be tedious to undo. Removal is exact: demo albums and people carry a flag, and the photos are found by the content hash of the bundled originals, so nothing of the user's own is caught in it.
- **Never seed it unasked.** A first launch opens on a genuinely empty library. Demo content put there automatically mixes somebody else's pictures in among the user's own the moment their real library arrives, and makes the first thing the app ever shows them a lie about what it holds. Offer it on the empty state and leave it at that — an empty library is a *correct* state, not an embarrassing one to paper over.
- Seeding must be idempotent by fixed id / content hash, with a "Reset Demo Data" action that re-adds only what's missing.
- Spread demo timestamps across several days and years — otherwise date grouping demos itself as one giant "Today" pile.
- Demo media should have visible pattern/motion, not flat colour.
- Demo relationship data should be realistic: only the closest few have avatars or photos; the rest are name-only. Everyone having everything looks fake.

```
✗ all createdAt = now          ✓ backdated across days/years
  Today                          Yesterday
  ▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦           ▦▦▦▦
  ▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦▦           Jul 31, 2026
  ▦▦▦▦▦▦▦▦▦▦▦▦                   ▦▦▦▦▦▦▦▦
  one giant pile — the day        Mar 12, 2011
  grouping demos nothing          ▦▦▦
                                  grouping demonstrates itself
```


### Local backup

must natively support backup all configs and app data to mobile local storage, and can import from it.
Purpose is to survive phone change, app reinstall...
And can support cloud bucket backup if confirmed in design.

- **Know what survives a reinstall, because it isn't what you'd guess.** On iOS the app's container — database, caches, files — is deleted on uninstall, while **Keychain items survive it**. Put a flag in secure storage and it outlives the records it describes: reinstall, and the app is certain it has already seeded a library that is now empty. Keep state next to the data it's about (same database file), and keep secrets in the Keychain, which is the one thing worth surviving.
- Never record a file by its picker/temp path. Copy into app-owned storage (hash-named) before recording.
- Never treat an absolute path as a durable handle: container UUIDs change on reinstall. Re-resolve by filename, and heal stale records on read.

```
✗  record the picker's path directly
   /tmp/pick-9f2a/IMG_4934.jpg        ← OS clears temp; container UUID
                                        changes on reinstall ⇒ silently
                                        unopenable asset

✓  copy into app-owned storage first, hash-named
   <appSupport>/<sha256>.jpg
   and on read, if the stored path is gone, re-find by filename
   under the CURRENT app-support dir and heal the record
```


### Cloud Bucket Backup

Applicable cloud bucket: S3, S3-compatible, Azure, Google

Call it **Private Cloud** — the point is storage the user owns.

Show the roadmap honestly: a storage-type picker listing every vendor, with unbuilt ones visibly disabled as "(coming soon)" rather than hidden.

Scope rule: object storage the user owns is in scope; consumer cloud *apps* (iCloud Drive, Google Drive, Dropbox) are not — those already have official apps.

**A key prefix names a folder**, so normalize it to end in `/` (and never start with one) rather than rejecting it. Typed as `photos`, it would put every object at `photosoriginals/…` — one missing character silently scattering a backup across the bucket root. There's only one thing the user can have meant; add the slash, and show the corrected value back so nothing is filed under a name they didn't type.

Key layout under the connection's prefix: `thumbnails/` `medium/` `originals/`, so the user's own bucket lifecycle rules can target each tier. Storage class/tiering is the bucket owner's business, configured in their cloud console, not in the app.

```
s3://<bucket>/<prefix>/
      ├── originals/     full-resolution tier   ← "original" = RESOLUTION tier,
      ├── medium/        display copies            NOT "unmodified bytes"
      └── thumbnails/    grid tiles

  each tier separately targetable by the user's OWN lifecycle rules
  (Standard → IA → Glacier). The app never sets a storage class.
```

**Credentials arrive as text, so take text.** Retyping a 40-character secret off a phone keyboard is where this form actually fails — the values are already together in a password-manager note or a `.env`. So the field group's own header carries a bracketed button that swaps the fields for a paste box *in place*: one paste fills them and snaps straight back, because seeing the four fields filled is the confirmation. The fields are the form; the paste is a shortcut into them, not a second input above them.

```
 S3 Bucket (paste info to add)      ← the bracket is the tappable part
 ┌──────────────────────────────┐
 │ Access key ID                │
 │ Secret access key            │   tap the bracket ↓
 │ Bucket                       │
 │ Key prefix                   │
 └──────────────────────────────┘

 S3 Bucket (back to fields)         ← same spot, label flips
 ┌──────────────────────────────┐
 │ bucket: my-photos            │   fields are REPLACED, not pushed down
 │ prefix: bring-your-own-…/    │   one paste ⇒ parse, fill, flip back
 │ access_key_id: AKIA…         │   typing it out by hand keeps the box open
 │ secret_access_key: …         │   the buffer is cleared on every toggle
 └──────────────────────────────┘
 "name: value" or "name=value", any spelling. Region still detected.

 parses liberally: AWS_ACCESS_KEY_ID=… · export … · "bucket": "my-photos",
                   s3://my-photos/raw/ · Access Key ID : …
 splits on the FIRST separator only — a base64 secret contains / + =
 a key with an empty value fills nothing, so a half paste can't blank a
 field someone already typed
```

✗ A permanent paste box above the form is paid for on every visit — including the edits and retries where nobody pastes — pushes the real fields below the fold, and leaves a pasted secret sitting in view above the fields it already filled.

Name collision to pre-empt: `originals/` means *full-resolution tier*, not *unmodified bytes*. If an "optimized" upload option exists, say so in the UI or it reads as a bug.

Page layout — **one flat page, no sub-pages.** The bucket list is the subject; everything else is a setting governing it, stacked below. Two sub-pages ("Backup Queue", "Backup Settings") hanging off it was the worst thing about the old design: the page became a menu of menus, and the thing you came for was two taps away.

```
✗ page as a menu of menus            ✓ one flat page
┌──────────────────────────┐         ┌──────────────────────────┐
│ Backup Queue        ›    │         │ Cloud Buckets        ⊕   │ ← the subject,
│ Backup Settings     ›    │         │  ☁ slmx-archives2   ⋯    │   first
│                          │         │  1 bucket · 56 of 57     │
│ Cloud Buckets       +    │         │  Sync queue: idle   ›    │ ← opens a SHEET
│  ☁ slmx-archives2   🗑   │         │ ──────────────────────── │
└──────────────────────────┘         │ SYNC FREQUENCY  Manual ▾ │ ← the settings,
  the subject is third, and          │ BACKUP FORMAT            │   below it
  every control is behind a push     └──────────────────────────┘
```

What goes where:
- **Per-connection** (browse, sync, delete) → that row's own `⋯` sheet. Never a second tap target beside the row.
- **Global to syncing** (frequency, format) → a section on the page. A setting whose value needs a sentence of pro/con is a list, not a menu item — menus can't carry the explanation.
- **Transient** (the queue) → a sheet over the page, opened from the one status line. Not a destination.

Scope a setting where it actually applies, not where a pattern says it should. Per-connection auto-sync is right when each connection is an independent source; here every connection *mirrors the same library*, so one sync run always fans out to all of them — a per-connection frequency would be a lie. It stays global, and says so by living on the page rather than in each bucket's menu.


Add connection:
- Ask for bucket + credentials + prefix. Nothing else.
- **Auto-detect the region** from the bucket name; never make the user type it. (S3's global endpoint returns `x-amz-bucket-region` even unauthenticated.)
- Validate real access *before* saving, using the same permission real syncs need — use a request that returns a diagnostic body (`GET`/list), not one that can't (`HEAD`), or failures degrade to a bare status code.
- Connection row: bucket name, `s3://bucket/prefix/`, region, and the row's `⋯`. The full path is the subtitle because two connections to the same bucket differ only by prefix — showing the region alone can't tell them apart.

```
Cloud Buckets                                             ⊕
Photos upload to storage you own. Credentials stay on
this device and go straight to the bucket.

┌────┐  slmx-archives2                                    ⋯
│ ☁  │  s3://slmx-archives2/bible-audio/photos/
└────┘  ca-central-1              ↑ the prefix is what tells two
                                    connections to one bucket apart

1 bucket · 56 of 57 photos backed up      ← stats footer: per-BUCKET counts
Sync queue: idle  ›                         aren't shown, because every bucket
                                            mirrors the same library — repeating
   ↑ global across connections, so it        one number per row is noise, not data
     lives here once, not behind each
     bucket's menu. Opens a sheet.
```

Browsing:
- Root the browser at the connection's **prefix**, and don't allow navigating above it. That prefix *is* the connection.
- Recurse by pushing the same screen with a deeper prefix — no separate detail screen, no per-level differences.
- Every level carries the same `…` menu and the same one-line stats footer.
- Page past listing limits with an explicit "Load More".
- Tapping a file previews it: presigned GET (never make the object public), images inline with pinch-zoom, anything else offers "Open Externally".

```
   s3://bucket/          ╳  NOT reachable — outside the connection
        │
        └── photos/      ◀── browser ROOT ( = the connection's prefix)
             ├── originals/        push the SAME screen, deeper prefix
             │    └── 2026/        …and again. No per-level differences:
             │         └── …        same ⋯ menu, same stats footer, every level
             ├── thumbnails/
             └── notes.txt         tap ⇒ preview via presigned GET
                                   (image inline · else "Open Externally")
```


Sync frequency:
Manual, every xx...
- Manual (default, no auto sync) / 15 min / 30 min / hourly / 6h / 12h / daily.
- Show "Last synced: …" in the same menu, directly under the options.
- "Sync Now" is always available regardless of the frequency setting.
- Without a registered OS background task, a frequency only fires while the app is foregrounded — say that in the hint.


Queue:

**A real, persisted queue — not a view derived from record statuses.** If "the queue" is just a filter over states, there is no queue: nothing can be paused, retried, or run concurrently.

```
✗ FAKE — a view over record statuses     ✓ REAL — its own job table
  SELECT * FROM photos                     ┌──────────────────────────┐
  WHERE status != 'uploaded'               │ id · ref · kind · status │
                                           │ error · timestamps       │
  nothing to pause                         └──────────────────────────┘
  nothing to retry individually              claim on dequeue (in a txn)
  no concurrency                             pause · speed · retry · clear
  "clear" can only mean "delete data"        "clear" just drops jobs
```

- Job table: id, target/asset ref, kind, display name, status (pending/running/done/failed), error message, timestamps.
- **Every** unit of work is a job — metadata/hash checks and thumbnail work too, not just the big uploads. If the app is doing something, it must be a visible row.
- Label each row by kind ("Backing up original", "Backing up thumbnail", "Checking for changes") so the list explains itself.
- **Cap it, and top it up.** A queue holds at most ~100 unfinished jobs; past that, enqueue refuses. A camera roll is hundreds of thousands of assets, and a queue that long is neither reviewable nor cancellable — it's a list nobody can act on, and it turns "pause" into a promise about something that already happened. A library bigger than the cap goes up a queueful at a time, refilled as each one drains. Refilling only ever *continues* a sync that was already running; a drain that found nothing to do must not go looking for work, or "Manual" stops meaning manual.
- **Paused means paused in both directions**: nothing new is taken *and* nothing more is processed. A queue that keeps growing while stopped is just a delayed surprise. Say which it is on the header — a queue quietly refusing work looks identical to one with nothing to do. Jobs already in flight are allowed to finish; an upload killed mid-request leaves a partial object in the bucket, which costs more than the second it saves.
- Claim on dequeue inside a transaction, so two workers can't take the same job.
- Bounded concurrency, user-visible and adjustable: "Speed: N at a time", default 2, range 1–8.
- Pause / resume, persisted.
- Clear Finished and Clear Queue as separate actions. Clearing changes **no** underlying data — the next manual or scheduled sync simply re-queues it.
- Per-job Retry on failure, with the error text inline on the row.
- Requeue jobs orphaned as `running` at launch: a kill mid-sync must not strand them.
- A job may enqueue follow-up jobs (a change check that finds drift queues its own re-upload).
- Never await a whole sync inline on a UI call stack. Enqueue and return.
- Summary line where connections are listed: `Sync queue: idle` / `Sync queue: 12 pending · 2 at a time`.
- Long queues: paginate the visible list, but count totals in the query, not off the visible page.

```
                    Sync Queue
Queue (45)                                      ⏸    ⋯
╭──────────────────────────────────────────────────────╮
│ beach.jpg                                    Waiting │
│ Backing up original            ← kind, so the list   │
├──────────────────────────────────  explains itself ──┤
│ sunset.jpg                                       ◐   │  running
│ Checking for changes             ← metadata work is  │
├──────────────────────────────────  a job too ────────┤
│ harbour.jpg                                      ✓   │  done
│ Backing up thumbnail                                 │
├──────────────────────────────────────────────────────┤
│ cliff.jpg                                    ↻       │  failed → retry
│ Backing up original                                  │
│ Access denied                  ← error inline, orange│
╰──────────────────────────────────────────────────────╯

⋯  Speed: 2 at a time      [ − ]  [ + ]      ← bounded concurrency, visible
   Clear Finished                              and adjustable (1–8)
   Clear Queue             (destructive)     ← drops JOBS, never data
```

State machine — nothing is ever stranded:

```
   enqueue ──▶ pending ──claim (txn)──▶ running ──▶ done
                  ▲                        │
                  │                        └─ throw ──▶ failed ──┐
                  │                                              │
                  └──── retry ◀─────────────────────────────────-┘
                  ▲
                  └──── requeueStaleRunning() at launch
                        (a kill mid-sync must not strand a `running` row)
```

Change detection (has this file changed since backup?):
- Re-hash the local file and compare against the hash stored at the **last successful upload**.
- Don't compare against the provider's ETag — not a reliable MD5 for multipart uploads, so large files false-positive.
- Drift → mark pending → re-upload.

```
local file ──hash──▶ ┌── same as hash-at-last-upload? ──▶ yes ⇒ nothing to do
                     └─────────────────────────────────▶ no  ⇒ pending ⇒ re-upload

✗ compare against the provider's ETag — not a real MD5 for multipart
  uploads, so every large file false-positives as "changed"
```

Upload format options:
- Original vs Optimized (re-encoded), each with a one-sentence pro/con on the option itself. Two options with a sentence each is a list of rows, not a menu.
- Videos upload as-is unless there's a real transcoder — don't imply otherwise.

Delete a control the engine stopped consulting. A "backup order" toggle (mirror each photo across buckets, vs fill one bucket first) was real while a batch loop walked the targets; once sync became per-file jobs that each fan out to every target, nothing read it any more. It looked like a working preference and changed nothing — worse than never having shipped it. Either the job model regains the granularity the control describes, or the control goes.

Sync should be **metadata-only by default**, with bytes fetched lazily per visible cell. Never turn a sync into a bulk local copy of the whole remote library. Say so in the section hint: "Sync only fetches metadata — files download when you open them."

Reclaiming device space:
- "Remove from Device" keeps the cloud copy. The item stays in every library view, drawn from a locally cached thumbnail, badged as cloud-only.
- Cache a thumbnail locally for **every** item — including ones too small to warrant a separate cloud thumbnail — precisely so there's something to draw afterwards.
- The detail screen then offers "Download Full Resolution".
- Don't offer it for items that aren't backed up, or have no thumbnail to fall back on.
- Deleting: offer "Remove from Device" vs a real delete. Keep the trash/Recently Deleted safety net, and purge the remote copy at *permanent* delete — not at soft delete, or "Restore" is lying.

```
  on device, backed up          Remove from Device            Download Full Resolution
  ┌──────────┐                  ┌──────────┐                  ┌──────────┐
  │  full    │  ─────────────▶  │ ☁ thumb  │  ─────────────▶  │  full    │
  │  photo   │                  │  only    │                  │  photo   │
  └──────────┘                  └──────────┘                  └──────────┘
   original on disk              space freed;                  re-fetched from
                                 STILL in every                originals/ on demand
                                 library view

  ⇒ cache a thumbnail for EVERY photo — including ones too small to be worth a
    separate cloud thumbnail — or there's nothing left to draw afterwards.

  delete ⋯                                 remote purge timing
  ├─ Remove from Device  (keeps cloud)     soft delete ─▶ Recently Deleted
  └─ Delete Photo        (to the trash)                      │  keep remote
                                                             ▼
                                            permanent delete ─▶ purge remote
                                            (purging at soft-delete makes
                                             "Restore" a lie)
```

Thumbnails:
- ~320px longest edge, quality ~70 → roughly 15–30 KB. Bigger is wasted on a grid tile.
- If the original is already under ~64 KB, skip the separate cloud thumbnail (the original is no bigger) but still keep the local cache copy.


### AI Intelligence

Ask input of API key.
Support multiple vendors.
Ask method of how to use API key.
Can support multiple model selections under each vendor, if confirmed by design decicion.

- Multiple keys, any mix of vendors, added one at a time.
- Fallback strategy as an accent control on the section heading row: `Sequential ▾` / `Round Robin ▾`. Sequential is sticky (moves on only when a key errors); round-robin spreads load every call.
- Order matters — reorder rows with ↑/↓; delete via the row's own menu.
- Show a per-key request count as the row's secondary value, so it's obvious which keys carry traffic.
- Hint must state: what it's used for, that keys go straight from the device to the chosen vendor, that they never leave the device otherwise (including backups), and that adding more than one gives automatic fallback on rate limit / quota.
- Warn that usage is billed to the user's own account with that vendor.
- Only list vendors that can actually do the job (don't offer a vision feature a vendor has no vision model for) — a key that can never work is worse than no option.
- Expensive analysis is **opt-in per run** ("Analyze"), never automatic, and results are cached locally.
- Image editing is a narrower capability than vision — a key that can only *read* images must fail over to one that can *return* one, not error the whole request.
- Long AI work runs detached from the screen that started it: an inline "AI working…" status, the result filed into the library when it lands, and the source photo untouched either way.

Layout follows the standard section anatomy at the top of this doc — key rows in a flat list, `+ Add AI Key` as a centred accent link closing it, and **adding one is a half sheet**, not a form parked permanently under the list. Two fields don't need a page, and a page-wide input box sitting under the keys is paid for on every visit including the ones where nobody is adding anything.

```
      ┌────────────────────────────────────────┐
      │ Cancel        Add AI Key         Save  │
      ├────────────────────────────────────────┤
      │ Vendor                    OpenAI  ▾    │
      │ API key                                │
      │ [ sk-…                               ] │ ← masked; placeholder is the
      │ Don't have an OpenAI key?   Get one →  │   vendor's own key shape
      └────────────────────────────────────────┘
```

The strategy control stays put but goes **inert below two keys** — with one key there's nothing to fall back to, and a live control that changes nothing is worse than a dim one. The two strategies:

```
Sequential ▾   key1 ──✓──▶ done      sticky: stays on key1 until it errors
               key1 ──✗──▶ key2      (rate limit / quota / revoked)

Round Robin ▾  call 1 ─▶ key1        advances every call, win or lose —
               call 2 ─▶ key2        spreads load instead of favouring one
               call 3 ─▶ key1
```


### App icon

- Generate to the full icon set from a single source, scripted and re-runnable.
- Full-bleed to 1024×1024 and let the OS do the corner rounding. A source that bakes in its own rounded card or drop shadow produces a visible double edge against the OS mask.
- Flat single-hue reads generic — gradient + soft glow + a little depth carries better at small sizes.

```
✗ source bakes in its own card     ✓ full-bleed 1024×1024
  ╭──────────────╮                   ┌──────────────┐
  │ ╭──────────╮ │ ← source's own    │              │
  │ │  glyph   │ │   rounded edge    │    glyph     │   OS mask does ALL
  │ ╰──────────╯ │ + iOS mask        │              │   the rounding
  ╰──────────────╯ = double edge     └──────────────┘
```
