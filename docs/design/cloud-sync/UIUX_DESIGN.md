# Cloud sync + browser extension: UI/UX

Why and scope: `DESIGN.md`. Drawings: `uiux/` (map in `uiux/README.md`).
Patterns from the `uiux` skill that apply: `cloud-bucket-sync.md` (connection
form, paste-to-fill, save proves access), `media-library.md` (day grid, viewer
with the info panel below, bin before purge), `credentials.md` (scoped key,
local-only storage).

## Stories → scenarios

| # | Story | Trigger → result | Edge / failure |
|---|---|---|---|
| S1 | As the owner, I want to open my library on my computer, so I can look at it on a big screen | click the toolbar icon → new tab, timeline from cache in < 300 ms, refreshes in the background | no connection yet → Setup · no checkpoint → "Open the app on your phone once" · offline → cached library + offline chip |
| S2 | I want to connect by pasting my bucket note | Setup → paste → Save → access proved → library loads | bad key → provider error verbatim, form stays filled · wrong prefix → "No Photos Vault library here" |
| S3 | I want to find a photo by day, album, person, place or word | grid / sidebar / search → viewer | 0 results → empty state with the query echoed |
| S4 | I want to drop photos from my computer into the library | drag onto the page → upload tray → tiles appear | HEIC → placeholder tile until the phone renders a thumbnail · upload fails → retry per row · tab closed mid-upload → resumes on reopen |
| S5 | I want to caption, favorite, tag and file photos into albums and people from the browser, and see it on my phone | edit in place → saved locally at once → synced within ~2 s | offline → queued, "3 changes waiting" · phone edited the same caption → "Edited elsewhere" choice on both |
| S6 | I want to bin a photo and undo it | Delete → toast with Undo → Bin page → Restore | permanent purge is phone-only; the Bin page says so |
| S7 | I want my phone to show browser edits with no action from me | phone foregrounds → pulls → grid patches | many changes → applied in background batches, no scroll jank |
| S8 | I want to know sync is healthy | status chip in both apps → Sync panel | an error names the cause and the fix |

## Screens & surfaces

```text
EXTENSION (one tab, sidebar layout)            PHONE (existing app)
Setup ............ page   S2                   Settings › Cloud Sync .. page  S8
Library .......... page   S1 S3                Sync status chip ....... on Library nav S7 S8
Viewer ........... overlay over any grid S3 S5 Conflict card .......... in the detail info panel S5
Albums / Album ... page   S3 S5                Bin row note ........... "Binned on Chrome" S6
People / Person .. page   S3 S5
Places / Place ... page   S3
Search results ... page   S3
Bin .............. page   S6
Upload tray ...... docked panel, bottom-right  S4
Sync panel ....... popover from the status chip S8 (conflicts listed here)
```

Viewer is an overlay, not a page: closing it has to land back on the same
scroll position in whichever grid opened it.

## Flows

```text
toolbar icon ─▶ has connection? ─no─▶ Setup ─save ok─▶ has checkpoint? ─no─▶ Waiting-for-phone
                    │yes                                     │yes
                    ▼                                        ▼
               Library (cache) ◀───────────────────────── first load ⟳ (progress by MB)
                    │ background pull every 30 s while visible
                    ▼
   tile ─▶ Viewer ─edit─▶ outbox ─2 s quiet─▶ segment PUT ─▶ chip ✓
                                   └─ offline ─▶ chip "3 waiting" ─online─▶ PUT

drag files ─▶ tray rows ─▶ originals/ PUT ─▶ thumbnail PUT ─▶ HEAD both ─▶ asset.add op ─▶ tile
```

## States
Drawn per screen in `uiux/`. Every extension page has at least:
- **first load** (progress)
- **cached** (instant, then a quiet refresh)
- **offline** (chip, edits queue)
- **empty**
- **error** (provider code verbatim)

## Components & copy
`uiux/components.md`: tile, day header, sidebar, status chip, toast,
upload-tray row, conflict card, empty state. Copy keys live with each screen.
The extension ships English and Simplified Chinese from day one, matching the
app (`chrome.i18n`, `_locales/en`, `_locales/zh_CN`).

## Deviations from the `uiux` skill
- No sync-frequency choice. The browser pulls while the tab is visible, and
  the phone on foreground plus every 2 min while open. A log pull is one cheap
  listing, so a "Manual" setting would only add a way to see stale data.
- No queue page for metadata ops. They're tiny and flush in ~2 s, so the
  chip's count is enough. Uploads *do* get a per-file tray (they're real jobs).
