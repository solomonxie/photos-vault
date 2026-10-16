# Fix Progress

Branch `fix/review-oct-2026`. One work package at a time (see `REPORT.md` section 5), each: code + tests,
one format/analyze/test pass, commit. Build and install at milestones.

| WP | Goal | Status | Commit |
|---|---|---|---|
| WP0 | Albums-home + sync change safe | ☑ | 92344fe |
| WP1 | P0 one-liners | ☑ | 3271214 |
| WP2 | Visibility predicate + face lifecycle | ☑ | 35d3d13 |
| WP7 | Absence never deletes (phone) | ☑ | 5c2e05c |
| WP6 | Vault & person recoverability | ☑ | 72298f3 |
| WP3 | Bucket delete gateway + tri-state probes | ☑ | 6bfcac2 |
| WP4 | Hidden transitions journal | ☑ | 5ebc612 |
| WP5 | Hidden data at rest | ☑ | 79e0072 |
| WP8 | Optimize swap journal + unique library_id | ☑ | ab1c63d |
| WP9 | Backup & restore reliability | ☑ | 0c42582 |
| WP10 | Store revisions + reload pipeline | ☑ | 8d7cb94 |
| WP11 | Flagged Items single scan | ☑ | c25c513 |
| WP12 | Faces package (05#4–#15) | ☑ | 65734b9 |
| WP13 | Remaining P2/P3 per findings file | ☑ | e67ac41, 4e12c47, 74b86fe, 88845bd |

Final release build (88845bd): 33.2 MB reported by flutter, `du` 31.9 MiB; App.framework 8.7 MiB (was 7.7 at baseline). 1454 tests pass.
