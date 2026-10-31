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

## Phone: Settings › Cloud Sync
```
‹ Settings          Cloud Sync
─────────────────────────────────────────────
Sync library to bucket                    ─●
Your albums, people, captions and favorites
live in the bucket so the Chrome extension
and your other phones see the same library.
Hidden photos never leave this phone.
╭──────────────────────────────────────────╮
│ Home bucket          sol-photos/vault/ › │
├──────────────────────────────────────────┤
│ Last synced                    just now  │
├──────────────────────────────────────────┤
│ Waiting to upload                     0  │
├──────────────────────────────────────────┤
│ Devices                              3 › │
╰──────────────────────────────────────────╯
first on    ⟳ Publishing your library… 41%   ← bootstrap checkpoint
```

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
