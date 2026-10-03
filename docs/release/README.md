# Release

- [listing.md](listing.md) — the whole App Store submission, field by field, ready to paste.
- [privacy-policy.md](privacy-policy.md) — published from this repo; its GitHub URL is the Privacy Policy URL in the listing.
- `screenshots/` — store-sized sets, written by `make screenshots FROM=<dir>`. Not tracked: capture them off the phone when you're ready to submit.

Build and upload: `scripts/release-ios.sh`.

## Decisions

### 2026-10 — China storefront: AI vendors

- **Why:** App Store review rejected the build — ChatGPT/OpenAI support violates China policy.
- **Plan:**
  - Store/region flag (storefront country, not device locale) hides vendors not allowed there.
  - Add existing China AI vendors to `lib/photos/ai_vendor.dart`.
  - Code path to force a region on the user's own phone (debug/demo setting), so the China build can be tested without a China Apple ID.
- **Status:** vendor gating built. App Store country (StoreKit) → `AppStoreRegion.current` → `aiVendorsFor` (cn: Qwen, Zhipu GLM, Kimi; us: the rest). Keys for the other region stay stored but are hidden and never called. AI Touch Up removed from the app (2026-10). cn defaults to Chinese unless a language is set in iOS Settings.
- No custom endpoints: dropped (2026-10), only the listed vendors.
- Testing on own phone: `make install-ios STOREFRONT=CHN` forces `cn`.

### 2026-10 — Rejected again (Guideline 5, build 202609242144)

- **Why:** metadata named OpenAI; that build predates the gating.
- **Fix:** region read at launch from the App Store account's country (StoreKit `storefront.countryCode == CHN`), not baked into the build — one binary ships to every storefront, so a build-time flag would either strip the US vendors or ship OpenAI to China. Release/archive never force `cn`.
- **Metadata:** no AI vendor named in description (en, zh) or privacy policy. Review Notes state the China suppression. Screenshots: check none shows the AI settings vendor list.
- **Decision:** AI off entirely in China mainland (`aiInChina = false` in `lib/photos/ai_vendor.dart`): AI Settings and profile AI options hidden, calls blocked. The licensed vendors stay in code for later.
