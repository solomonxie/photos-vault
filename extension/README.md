# Photos Vault for Chrome

A Google-Photos-like page over your own bucket: browse, upload, edit, bin.
The bucket is the source of truth; this page and the phone app are both
caches of it, synced through a per-device op log.

Design: `../docs/design/cloud-sync/` (`DESIGN.md`, `PROTOCOL.md`, `uiux/`,
`IMPLEMENT_PLAN.md`).

```
npm install      # local node_modules only
npm run check    # tsc
npm test         # vitest: protocol vectors, SigV4, engine
npm run build    # → dist/
```

Load: `chrome://extensions` → Developer mode → Load unpacked → `dist/`;
click the toolbar icon. After a rebuild, hit reload on the extension card.

- No media on this computer: thumbnails and views are presigned URLs
  (`response-cache-control: no-store`), never the Cache API or IndexedDB.
  IndexedDB holds only library metadata and the sync outbox.
- Icons: `static/icons/`, from the iOS 1024 px app icon via `sips -z`.
