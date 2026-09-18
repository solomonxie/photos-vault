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
 These keys power AI-recognized People and Events smart collections.
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

## AI Touch Up  (from the viewer's Edit menu)

```
 ┌──────────────────────────────────────────────┐
 │ AI Touch Up                                  │
 │ ┌──────────────────────────────────────────┐ │
 │ │ Describe the edit — "brighten it and     │ │
 │ │ remove the fence"                        │ │
 │ └──────────────────────────────────────────┘ │
 │ The photo and your prompt are sent to your   │
 │ AI vendor, and the result comes back as a    │
 │ new photo — this one stays as it is.         │
 │        ( Cancel )        [[ Start ]]         │
 └──────────────────────────────────────────────┘
 running  ⟳ AI working…        ← on the library page, under the nav bar,
                                 not a blocking spinner: it takes a while
 done     AI touch-up added to your library.
 failed   AI touch-up failed: <vendor's words>
 no key   Add an AI key in Settings first.
```

## AI Suggest (info panel)

```
 Add a description                          ✨ AI Suggest
 no key    Add an AI key in AI Settings to use this.
 nothing   Nothing to suggest for this photo.
```
