# The people feature, held against a relationship manager

A second app idea — **RIM**, relational info management — overlaps this
app's People feature almost exactly. Worth reading as a review of what is
here: where RIM's plan is better, where it is a different app, and where it
wants something this app already built.

## Where they already agree

| RIM plans | here |
|---|---|
| person profile: basic info, relations | `PersonProfileScreen` — bio, job, education, family |
| relationship graphs | `person_graph_screen.dart`, hand-rolled `CustomPainter` |
| backups: local, iCloud, S3 | three app-data tiers, plus S3/COS/OSS for media |
| media: pictures, videos | the whole library |
| passcode that shows a *different world*, never a wrong code | private albums, and `album_index.dart`'s padded sections |
| all media encrypted | hidden photos: AES-256-CTR, encrypt-then-MAC |

The last two are the interesting ones: RIM lists them as goals; this app has
them shipped, and the hard half — an index where the code you type selects
which world exists, with no way to tell an empty world from a wrong code —
is the part that is already written and tested.

## What RIM has that this app should take

### 1. The lock on a person contradicts the lock on an album

A private album has no wrong passcode, on purpose, and the README explains
why: an error state is what leaks. A **person profile** lock is a passcode
*with a hint and a wrong state* — the exact design the album rejected, in
the same app, two screens apart.

RIM's version ("no wrong code, a different code shows a different world")
applied to any list is the consistent one. Either make the person lock
behave like the album's, or say in the copy that it is a different, weaker
thing and why. Today it silently is.

### 2. Events should be entities, not a string

An event here is free text on a photo (`event`, grouped in
`_groupedBy`). RIM's "story graphs" make a story a node with people, a
place and a time hanging off it. The small version of that is worth it on
its own: an Event with an id, linked to people and photos, rendered in the
graph that already exists. It turns "who is this" into "when were these
people in the same room", which is the question a photo library can answer
and a contact manager cannot.

### 3. Genealogy is a second layout, not a second feature

Typed relationships are here; generational layout is not. The current graph
unions family relationships into clusters and rings them around a circle —
right for "who knows whom", wrong for "who descends from whom". A family
tree is a DAG laid out by generation. Same data, second painter.

### 4. Printing a profile

RIM: "easy print profiles and graphs". Nothing here renders a person to
anything shareable. Cheap route that respects the size budget: paint the
existing profile and graph into an image and hand it to the share sheet
already wired up — no PDF package, no new megabyte.

### 5. Bio fields are the least protected data in the app

`lib/vault/README.md` is emphatic that nothing about the private side goes
in sqlite, because sqlite rides to the bucket in the daily snapshot. Person
bios — job, education, family, relatives, relocation history — go in that
same sqlite, in plaintext, and into that same snapshot. They are arguably
more sensitive than any photo's EXIF.

RIM's "database stored as a single encrypted file" is the blunt version of
the right instinct. The proportionate version here: encrypt the bio and
relationship columns with a key in the Keychain, so the snapshot carries
ciphertext and a restored phone needs the device it came from.

## What not to take

- **Subscriptions and a cloud sync service.** A sync service is a server.
  This app's entire argument is that there is no server and no account;
  selling a subscription to one would be selling the thing it refuses to
  be.
- **REST API extensions.** A personal photo library on a phone has no
  caller.
- **Flight search.** A genuinely different app that happens to also use
  graphs.
- **3M nodes.** RIM's bound is 150³. The graph here draws the people in
  one person's life — tens, occasionally hundreds. A layout that scales to
  millions is a different data structure and a different renderer, bought
  for a case that does not exist here. State the real bound instead.

## What this app has that RIM's plan is missing

RIM lists "build person profile" with no way to fill one. That is where
relationship managers die: the data entry is the product, and nobody does
it twice.

Here, faces come out of photos the user already has, a name given once
suggests itself on the next photo, and the profile is a thing that already
has content before anyone types. If RIM is ever built, this is the feature
it should start from rather than the graph.
