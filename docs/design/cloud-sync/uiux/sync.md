# Sync status: extension and phone

## Extension status chip (top-right of every page)
```
✓ Synced            all ops flushed, pulled < 1 min ago
⟳ Syncing…          a pull or flush in flight
↑ 3 waiting         ops sealed, not yet in the bucket
⚠ 1 conflict        an open conflict (opens the panel)
⚠ Sync stopped      fatal: collision / newer protocol / clock rejected
Offline             navigator.onLine false or the last request failed on network
```

## Sync panel (click the chip)
```
                     ┌─────────────────────────────────────────────┐
                     │ sol-photos/vault/                           │
                     │ Last synced  just now                       │
                     │ This browser  Chrome on Mac · 0 waiting     │
                     ├─────────────────────────────────────────────┤
                     │ DEVICES                                     │
                     │ iPhone 14          last seen 2 min ago      │
                     │ iPhone SE          last seen Oct 30         │
                     ├─────────────────────────────────────────────┤
                     │ CONFLICTS (1)                               │
                     │ IMG_4934 · description                   ›  │ ← opens the Viewer
                     ├─────────────────────────────────────────────┤   on its card
                     │ ( Sync now )                                │
                     └─────────────────────────────────────────────┘
fatal   │ ⚠ Sync stopped: this extension is older than the     │
        │ library (protocol 2). Update it to keep syncing.     │
        │ Browsing still works; edits are kept here.           │
```

## Phone: Settings › Library Sync
A group on the Settings page, between App Data and Cloud Buckets, not a
page of its own: one switch and what it needs.
```
LIBRARY SYNC
╭──────────────────────────────────────────╮
│ Sync Library to Bucket               ─●  │
│ Last synced 2 min ago                    │ ← or "Publishing your library… 4,210",
├──────────────────────────────────────────┤   or the bucket's error, or "Sync stopped: …"
│ Home Bucket                sol-photos  › │ ← only with 2+ buckets; fixed after first sync
├──────────────────────────────────────────┤
│ Waiting to Upload                     3  │ ← only when > 0
├──────────────────────────────────────────┤
│ Edited in Two Places                  1  │ ← only when > 0
├──────────────────────────────────────────┤
│ Sync Now                                 │
╰──────────────────────────────────────────╯
Albums, people, captions and favorites live in your bucket, so the
Chrome extension and your other phones see the same library. Hidden
photos never leave this phone.
```
Off pauses the network only; edits keep being queued and go up when it's
back on.

## Phone: status on the Library nav bar
It shows only when something is off. A healthy sync has no badge.
```
Library                          ⚠ 1        ← tap → the photo's conflict card
```

## Phone: conflict card in the detail info panel
```
╭──────────────────────────────────────────╮
│ ⚠ Description edited in two places       │
│ This iPhone:  Cascais beach              │
│ Chrome · 2 min ago:  Beach, day 2        │
│      ( Keep this )   ( Use Chrome's )    │
╰──────────────────────────────────────────╯
```

## Phone: bin row
A photo binned from the browser shows `Binned on Chrome` under its date
in the Bin.
