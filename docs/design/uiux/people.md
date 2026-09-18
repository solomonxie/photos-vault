# People

## People list  `lib/viewer/people_screen.dart`

```
 ‹                People                          ＋
 ┌─────────────────────────────────────────────────┐
 │ 🔍 Search                                       │
 └─────────────────────────────────────────────────┘
 ◯  Mei                                      61  ›
 ◯  Sam                                      12  ›
 ─────────────────────────────────────────────────
 ✨ Find People with AI Analysis                  ›   → smart collection
 empty        No people yet. Tap + to add someone.
 no matches   No people match your search.
 ＋ ⇒ alert: New Person · [ name ] · ( Cancel ) ( Add )
```

## Person page  `lib/viewer/person_page_screen.dart`

```
 ‹                 Mei                            ＋   → Add Photos
 ┌─────────────────────────────────────────────────┐
 │   ◯ 96pt avatar                                 │
 │   Mei                                        ›  │ ← the whole name line
 │   61 photos                                     │   opens the profile
 └─────────────────────────────────────────────────┘
 ┌──────┬──────┬──────┐
 │      │      │      │   same day-grouped grid as the library
 └──────┴──────┴──────┘
 empty   No photos tagged yet.
 hold a tile ▸ ♥ Favorite
              ◯ Use as Profile Photo
              👤− Remove from Person
              🗑 Delete                !
```

## Profile  `lib/viewer/person_profile_screen.dart`

Identity and photos stay visible whatever the lock says; only the detail
sections hide.

```
 ‹               Profile                      Lock Profile
 Name                                              ← field, placeholder
 Mei
 34 years old  ·  Female                           ← each half tappable
 About                                             ← field, placeholder
 …
 Education                                      ⊕
 Kyoto University            2014 – 2018        ›  → history detail
 Job                                            ⊕
 Designer, Acme              2019 – Present     ›
 Relationships                                  ⊕
 ◯ Sam            Spouse                        ⊗
 ◯ Ken            Colleague · Acme              ⊗
 View Relationship Graph                        ›
 Places Lived                                   ⊕  always last
 Kyoto            Origin                        ⊗
 Berlin           Relocation   2019 – Present   ⊗
 Custom Fields                                  ⊕
 Field                 Value
 [ Delete Person ]!   ⇒ Delete this person? Removes their profile and
                        relationships. Photos stay in your library.
 Not set          ← every unfilled value reads this, never a blank
```

```
 locked                              unlocking
 ‹      Profile          Unlock      ┌────────────────────────┐
 🔒 This profile's details are       │ Enter Passcode         │
    locked.                          │ [ •••• ]               │
 Hint: my first cat                  │ Incorrect passcode.    │
                                     └────────────────────────┘
 setting a lock
 ┌──────────────────────────────────────────┐
 │ Lock Profile                             │
 │ Choose a passcode to hide this profile's │
 │ details.                                 │
 │ Passcode        [ •••• ]                 │
 │ Hint (optional) [           ]            │
 │        ( Cancel )      [ Save ]          │
 └──────────────────────────────────────────┘
 removing it ⇒ Remove the lock on this profile? [ Delete ]!
```

Relationship picker and its types:

```
 Link to Person
 ◯ Sam · ◯ Ken · ◯ Aya …
 [ FAMILY | Spouse | Parent of | Child of | Sibling | Friend |
   Colleague | Schoolmate | Other ]
 Colleague ⇒ asks Company · Schoolmate ⇒ School · else Organization
 ⊗ ⇒ Remove this relationship?
     This only removes the link between Sam and this profile — neither
     person is deleted.
```

## History detail  `lib/viewer/person_history_detail_screen.dart`

One job or one school, in full.

```
 ‹          Kyoto University                  Save
 ┌ START ─────────────┤ 2014                      │
 ├ END ───────────────┤ [ PRESENT | End Date ]    │
 ├ MAJORS / DEGREES ──────────────────────────  ⊕ │  "Titles" for a job
 │ Title                                       ⊗  │
 │ Description                                    │
 ├ PROJECTS ──────────────────────────────────  ⊕ │
 │ Project Name                                   │
 │ Tags, comma separated                          │
 ├ AWARDS ────────────────────────────────────  ⊕ │
 ├ NOTES ─────────────────────────────────────────┤
 └────────────────────────────────────────────────┘
 [ Delete Entry ]!   ⇒ Delete this entry?
```

## Relationship graph  `lib/viewer/person_graph_screen.dart`

Hand-rolled layout, no graph package.

```
 ‹        Relationship Graph
        ╭──── family circle ────╮
        │   ◯ Mei ── ◯ Sam      │   family / spouse / parent / child /
        │        ╲   ╱          │   sibling cluster into one circle
        │         ◯ Aya         │
        ╰───────────────────────╯
                 │  colleague          other types = plain lines between
                 ◯ Ken                 clusters, styled by type
 empty   Add relationships to see the graph.
```
