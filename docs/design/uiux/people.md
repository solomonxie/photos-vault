# People

## People list  `lib/viewer/people_screen.dart`

```
 ‹                People                          ＋
 ┌─────────────────────────────────────────────────┐
 │ 🔍 Search                                       │
 └─────────────────────────────────────────────────┘
 ◯  Mei                                      61  ›
 ◯  Sam                                      12  ›
 FACES TO NAME
 ◯  Nina?                                   [✓] ›  ← ✓ accepts, row opens
 ◯  Nina?                                   [✓] ›    the picker
 ◯  Who's this?                                  ›  ← no guess
 ─────────────────────────────────────────────────
 ✨ Find People with AI Analysis                  ›   → smart collection
 empty        No people yet. Tap + to add someone.
 no matches   No people match your search.
 ＋ ⇒ alert: New Person · [ name ] · ( Cancel ) ( Add )
```

Rows, not the home page's horizontal strip — this is the page you open to
work through them, and a sideways scroll inside a vertical one hides most
of its contents behind a gesture nobody makes here. Hidden while searching.

```
 accept ↓                       row leaves, count drops
 ⌐ Added to Nina   ( Undo ) ¬   ← 5s toast, because it was one tap
```

## Faces the app has a guess about

A face gets a name attached once somebody has been named a few times. The
app never links it — `Nina?`, and a tap confirms.

```
 home People row      ◯ Nina?      tap ⇒ picker, guess pinned at the top
 People page          ◯ Nina? [✓]  ✓ accepts in place
 detail face row      ◯  Nina?     tap ⇒ picker
 no guess             Who's this?  unchanged, and the common case
```

✗ tapping a suggested card accepts it outright
  one mis-tap in a scrolling strip tags the wrong person, and undoing it
  means finding the photo again — so only the *row*, which isn't scrolling
  sideways and has a visible ✓, accepts on one tap

Silence is a real answer. Nothing is suggested when nobody is named yet,
when the nearest person isn't near enough, or when two people are nearly
equally close — a coin flip presented as an answer is worse than the
question. See `../face-recognition/DESIGN.md`.

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


# Unnamed faces

The Library's People row is named profiles **then** the faces nobody has
put a name to, newest photo first, capped at twenty.

```
 People                                              More ›
 ( ● )      ( ● )      ( ◌ )      ( ◌ )
  Mia       Daniel    Who's this? Who's this?   ← dashed ring, grey caption
  148        92
```

A face with a dashed ring and a question instead of a name: it is not a
person yet, and a card that looked like one would claim the app knows who
this is. Tapping opens the photo, where the face can be tagged.

iOS finds faces but keeps identity to itself, so this is per-*photo*: a
photo with nobody tagged in it offers its faces, and once one person is
named there the rest go quiet — the app has no way to tell which remaining
boxes are still strangers, and guessing is worse than stopping.

The face boxes are stored (`ai_analysis` v3's `faces` column) rather than
re-found on the fly. A count can say "three faces here"; only a box can
draw one.

# New person

`+` on the People page creates the person and pushes straight to their
profile with the keyboard in the name field. No dialog asking for a name
and then a page asking for everything else.

The profile writes each field as it's typed, so there is nothing a "Save"
button would do. **A non-empty name is the save.** Leaving it blank is how
you back out: a nameless person is one nobody started, and it's dropped on
the way out rather than left in the list as an untitled row.

# Profile picture

Tap the avatar (it carries a small camera badge, or nobody tries) to pick
from **that person's own** photos — `person_avatar_picker.dart`, not the
library picker. A profile picture that isn't of them is the one thing this
can get wrong, and the full library would make it the easiest thing to do.

The face box is dropped along with the old photo: a crop only means
anything on the picture it was tapped in.

About is empty by default and says so — *This person doesn't have any bio*.
