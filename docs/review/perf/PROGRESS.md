# Perf Fix Progress

| PW | Goal | Status | Commit |
|---|---|---|---|
| PW1 | First photo fast on cold start | done | c919b28 |
| PW2 | Cheap resume | done | 257a92c |
| PW3 | No re-renders for thumbnails, Vision, hashing | done | (this commit) |
| PW3b | Upload true originals | needs decision | |
| PW4 | Faces without full descriptor reads | todo | |
| PW5 | Smaller database | todo | |
| PW6 | Less periodic waste | todo | |
| PW7 | Cheaper grid paint | todo | |
| PW8 | Cheaper reload and search | todo | |
| PW9 | The rest | todo | |

## PW3 notes

- BG-4: cache and bucket thumbnails from PhotoKit (fitted 320, JPEG q70, as `encodeThumbnail`); the full-size render only when PhotoKit has none.
- BG-10: Vision takes `photokit:<id>` sources, rendered natively at 2048 (`VisionAnalysisChannel.swift`). `facesWithPrints` detects and describes in one render; matching then reads stored descriptors. Files stay for held/hidden/manual and for pre-upright (legacy) boxes.
- BG-5: `hashFile` in an isolate; the pre-upload hash is reused after the put; optimizer hash off the UI isolate.
- BG-6: `change_check` table (schema v26): `seen` stamped by scans and the change history, `checked` set by an upload or a matching hash. Checks only where they differ. One-time cost: every backed-up photo is hashed once after upgrade (newest first, 100 per sync).
- Tmp: `TempRenders` holds renders in use; uploads, checks and thumbnail fallbacks delete their own after the transfer is terminal; a sweep on queue drain removes unheld renders older than 1 h. `clearFileCache` not used: it also empties `.video`, which playback and video uploads read.

