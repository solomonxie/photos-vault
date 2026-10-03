# AI

## AI Settings  `lib/settings/ai_settings_screen.dart`

Same flat dark section layout as Cloud Settings: the key list is the
subject, the fallback strategy is the one control on the heading, and adding
a key is a half sheet rather than a form parked under the list.

```
 ‹            AI Settings
 AI Keys                                        Sequential ▾
 Each analysis uses one configured key, trying the next on failure.
 Reorder with the arrows.
 ┌───┐ OpenAI                              ⌃  ⌄  ⋯
 │ ✨│ 42 requests
 └───┘
 ┌───┐ Google                              ⌃  ⌄  ⋯
 │ ✨│ 1 request
 └───┘
                   Add AI Key                     ← centred accent link,
                                                    not a filled button
 These keys power the AI-recognized People smart collection.
 Places (GPS-based) doesn't need them.
 ⚠ Enabling this sends photo data to whichever AI vendor's key handles
   the request, and incurs API usage charges billed to your account
   with them.
 ⋯ ▸ Remove Key !        → API key removed
```

```
 add sheet                      Sequential ▾ ⇒ [ SEQUENTIAL | Round Robin ]
 ┌─────────────────────────────────────┐
 │ Vendor                    OpenAI ▾  │
 │ API key         ••••••••••••        │
 │ Don't have a OpenAI key?  Get one → │
 │        ( Cancel )      [ Save ]     │
 └─────────────────────────────────────┘
 → API key saved
```

AI is used only for person profiles, text in and text out (2026-10). No photo is sent to a vendor: AI Touch Up and AI photo analysis were removed.
