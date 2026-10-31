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
```

The page itself (setup, grid, viewer) is Phase 4 — not built yet.
