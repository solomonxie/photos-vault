# sync

The phone's side of cloud sync: the bucket is the source of truth for
library metadata, this phone a cache. Protocol:
`docs/design/cloud-sync/PROTOCOL.md`.

```text
store write ─trigger─▶ sync_outbox (same db, same txn)       capture.dart
   ─collect─▶ sync.db outbox ──────────────────────────────── translate.dart
   ─seal────▶ stamped segment (HLC, version vector)           log_sync.dart
   ─flush───▶ sync/log/<device>/<seq>.ndjson.gz, write-once   log_bucket.dart
bucket ─pull─▶ merge (LWW fields, OR-sets, conflicts) ─▶ sync.db entity rows
```

| File | Does |
|---|---|
| `hlc.dart` `op.dart` | stamps and ops |
| `merge.dart` | order-independent merge; same vectors as `extension/src/sync/merge.ts` |
| `segment.dart` `checkpoint.dart` | the two file formats |
| `capture.dart` | triggers; idle until enabled, silent while applying pulled ops |
| `translate.dart` | captured row → ops; hidden rows only ever say `hidden` |
| `sync_store.dart` | `sync.db`; backed up as a blob, restore re-queues unsent edits under a new device id |
| `log_bucket.dart` | write-once PUT, list, get over S3/COS/OSS |
| `log_sync.dart` | collect → seal → flush; pull; checkpoints |

Not wired into the app yet: nothing calls `setCapture`, so the triggers
stay idle. Applying pulled ops to the photo rows is Phase 3 of
`docs/design/cloud-sync/IMPLEMENT_PLAN.md`.
