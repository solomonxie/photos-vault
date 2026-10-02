# Release

- [listing.md](listing.md) — the whole App Store submission, field by field, ready to paste.
- [privacy-policy.md](privacy-policy.md) — published from this repo; its GitHub URL is the Privacy Policy URL in the listing.
- `screenshots/6.9/`, `screenshots/6.5/` — store-sized sets, written by `make screenshots FROM=<dir>`. Not tracked: capture them off the phone when you're ready to submit.

Build and upload: `scripts/release-ios.sh`.

## Decisions

### 2026-10 — China storefront: AI vendors

- **Why:** App Store review rejected the build — ChatGPT/OpenAI support violates China policy.
- **Plan:**
  - Store/region flag (storefront country, not device locale) hides vendors not allowed there.
  - Add existing China AI vendors to `lib/photos/ai_vendor.dart`.
  - Code path to force a region on the user's own phone (debug/demo setting), so the China build can be tested without a China Apple ID.
- **Status:** vendor gating built. `make … STOREFRONT=CHN` → Info.plist `AppStoreRegion` → `AppStoreRegion.current` → `aiVendorsFor` (cn: Qwen, Zhipu GLM, Kimi; us: the rest). Keys for the other region stay stored but are hidden and never called. AI Touch Up hidden in cn (no editing vendor there). cn defaults to Chinese unless a language is set in iOS Settings.
- No custom endpoints: dropped (2026-10), only the listed vendors.
- Testing on own phone: `make install-ios STOREFRONT=CHN`. Region is baked into the build, never read from the Apple ID, so no in-app override is needed.
