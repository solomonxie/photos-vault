import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/face_grouping.dart';
import '../photos/face_identity.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'asset_grid_view.dart';
import 'person_avatar.dart';

/// A person who doesn't exist yet: one face, every photo in the library
/// that looks like it, and a name field.
///
/// Laid out like the person page it is about to become — avatar, name,
/// then their photos as a full grid — so naming somebody is finishing a
/// page rather than filling in a form and hoping.
///
/// Nothing here is written down until the name is. That is what makes the
/// grouping safe to show: it is the app's opinion, visible and arguable,
/// rather than a pile it has already filed. Tap a photo that isn't them
/// and the app never learns the wrong face.
class FaceGroupScreen extends StatefulWidget {
  const FaceGroupScreen({
    super.key,
    this.seed,
    this.existing,
    required this.personStore,
    required this.assetRecordStore,
    required this.grouping,
    required this.faceIdentity,
  });

  /// The face that was tapped — always part of the group, never dropped.
  /// Null when gathering more photos of somebody already named, where the
  /// search runs from all of their confirmed faces instead of one.
  final UnnamedFace? seed;

  /// Somebody already named, when this is "find more photos of them".
  /// Their name is fixed, so the field is gone and Save is live at once.
  final Person? existing;

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;
  final FaceGrouping grouping;
  final FaceIdentityService faceIdentity;

  @override
  State<FaceGroupScreen> createState() => _FaceGroupScreenState();
}

class _FaceGroupScreenState extends State<FaceGroupScreen> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  List<Person> _people = const [];

  /// Somebody already named, picked from the list under the field. Null
  /// means the typed name makes a new person — the common case, and why
  /// the field is a field rather than a picker.
  Person? _chosen;

  List<UnnamedFace> _group = const [];
  List<AssetRecord> _records = const [];
  late final Set<String> _keeping = {
    if (widget.seed case final seed?) _keyOf(seed),
  };
  bool _loading = true;
  bool _saving = false;

  static String _keyOf(UnnamedFace f) => '${f.localId}:${f.face.encode()}';

  /// The face this page is about, when there is one.
  UnnamedFace? get _seed => widget.seed;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final existing = widget.existing;
    if (existing != null) _name.text = existing.name;
    final people = await widget.personStore.listAll();
    // Most-tagged first, so tapping the empty field offers the people you
    // actually photograph rather than whoever happens to sort first.
    final counts = <String, int>{};
    for (final person in people) {
      counts[person.id] = (await widget.personStore.localIdsIn(person.id))
          .length;
    }
    people.sort((a, b) => (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0));
    final seed = _seed;
    final group = seed != null
        ? await widget.grouping.like(seed)
        : await widget.grouping.likeAnyOf(
            await widget.faceIdentity.analysisStore.confirmedFaces(),
          );
    final faces = group.isEmpty && seed != null ? [seed] : group;
    // The grid draws records, and one photo can hold two of these faces —
    // so a photo appears once, whichever of its faces got in.
    final byAsset = <String, AssetRecord>{};
    for (final face in faces) {
      if (byAsset.containsKey(face.localId)) continue;
      final record = await widget.assetRecordStore.getByLocalId(face.localId);
      if (record != null) byAsset[face.localId] = record;
    }
    if (!mounted) return;
    setState(() {
      _people = people;
      // Everything the app thinks is them starts in — the common case is
      // that it's mostly right, and dropping three is less work than
      // picking twenty.
      _group = faces;
      _keeping.addAll(faces.map(_keyOf));
      _records = byAsset.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _loading = false;
    });
  }

  /// Which photos are still in. The grid selects records, not faces, so
  /// dropping a photo drops every face of it.
  Set<String> get _keptAssets => {
    for (final face in _group)
      if (_keeping.contains(_keyOf(face))) face.localId,
  };

  /// Whether every photo offered is in. What the one button reads as —
  /// Select All when something is out, Deselect All when nothing is.
  bool get _allKept => _keptAssets.length == _records.length;

  /// One button doing both, because they are never both useful: with
  /// everything in, the only move left is to clear it, and with anything
  /// out the only move is to take the lot. Two buttons would leave one of
  /// them dead at all times.
  ///
  /// Deselecting keeps the face you came from — dropping it would leave a
  /// person made of other people's photos.
  void _toggleAll() => setState(() {
    if (_allKept) {
      _keeping.clear();
    } else {
      _keeping.addAll(_group.map(_keyOf));
    }
  });

  void _toggle(AssetRecord record) {
    // Every tile toggles, the seed included. It used to be pinned — the
    // photo you came from being the one you're naming — but the grid is
    // oldest-first, so the seed sits at the bottom and reads as a tile
    // that simply doesn't work. If you drop it, the avatar comes from
    // whatever you kept instead.
    setState(() {
      final keys = _group
          .where((f) => f.localId == record.localId)
          .map(_keyOf)
          .toList();
      if (keys.isEmpty) return;
      final dropping = _keeping.contains(keys.first);
      for (final key in keys) {
        if (dropping) {
          _keeping.remove(key);
        } else {
          _keeping.add(key);
        }
      }
    });
  }

  /// Creates the person, links every kept photo, and teaches the app each
  /// kept face. The one moment any of this is written down.
  Future<void> _save() async {
    final name = _name.text.trim();
    if (_saving || _keptAssets.isEmpty) return;
    if (widget.existing == null && name.isEmpty) return;
    setState(() => _saving = true);
    final person =
        widget.existing ??
        _chosen ??
        await widget.personStore.create(name: name);
    final kept = _group.where((f) => _keeping.contains(_keyOf(f))).toList();
    await widget.personStore.addAssets(
      person.id,
      kept.map((f) => f.localId).toSet().toList(),
    );
    // The tapped face becomes their picture: it is the one that was on
    // screen when the user decided who this was. Somebody already named
    // keeps whatever picture they already had.
    // The face that was tapped, if it's still in — otherwise whatever
    // was kept, because a portrait has to come from a photo they're
    // actually in.
    final seed = _seed;
    final portrait = seed != null && _keeping.contains(_keyOf(seed))
        ? seed
        : kept.firstOrNull;
    if (person.avatarFace == null && portrait != null) {
      await widget.personStore.update(
        person.copyWith(
          avatarLocalId: portrait.localId,
          avatarFace: () => portrait.face,
        ),
      );
    }
    for (final face in kept) {
      final record = await widget.assetRecordStore.getByLocalId(face.localId);
      if (record == null) continue;
      await widget.faceIdentity.remember(
        record: record,
        face: face.face,
        personId: person.id,
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop(person);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Somebody already named needs no name typed, but still needs at
    // least one photo kept — Save that adds nothing is a button that
    // lies.
    // A name where one is needed, and at least one photo either way —
    // Save that adds nothing is a button that lies.
    final named =
        _keptAssets.isNotEmpty &&
        (widget.existing != null || _name.text.trim().isNotEmpty);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          widget.existing == null
              ? l10n.faceGroupTitle
              : l10n.faceGroupMoreTitle(widget.existing!.name),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          // Present but dead without a name, rather than missing: the rule
          // this screen is built on is "nothing is saved until you name
          // it", and a hidden button doesn't say that.
          onPressed: named && !_saving ? _save : null,
          child: Text(l10n.faceGroupSave),
        ),
      ),
      child: SafeArea(
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : Column(
                children: [
                  _header(l10n),
                  Expanded(
                    child: AssetGridView(
                      records: _records,
                      // Tap picks a photo in or out rather than opening
                      // it: on this page the question is "is this them?",
                      // and every tile is an answer to it.
                      onTap: _toggle,
                      selectedIds: _keptAssets,
                      // The face you tapped to get here, ringed — in a
                      // grid of near-identical photos it is otherwise
                      // indistinguishable from the forty it gathered.
                      markedId: _seed?.localId,
                      actionsFor: (_) => const <TileAction>[],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// The people this name could mean, unfolded under the field rather
  /// than behind a sheet: the choice is made from what is on this page —
  /// the face and their photos — and a sheet would cover exactly that.
  ///
  /// The typed name is offered as a new person whenever it isn't already
  /// somebody's, so "add to Nina" and "there's a second Nina" are both
  /// one tap and neither is the default.
  List<Widget> _nameOptions(AppLocalizations l10n) {
    final typed = _name.text.trim();
    if (_chosen != null) return const [];
    // Tapping the field with nothing typed offers the people you tag
    // most. Half the time the answer is one of four or five names, and
    // typing one out to find it is work the app can do instead.
    if (typed.isEmpty) {
      if (!_nameFocus.hasFocus) return const [];
      return [for (final person in _people.take(5)) _personOption(person)];
    }
    final query = typed.toLowerCase();
    final matches = _people
        .where((p) => p.name.toLowerCase().contains(query))
        .take(4)
        .toList();
    final exact = matches.any((p) => p.name.toLowerCase() == query);
    return [
      for (final person in matches) _personOption(person),
      if (!exact)
        CupertinoListTile(
          key: const ValueKey('pick:new'),
          leading: const Icon(
            CupertinoIcons.person_crop_circle_badge_plus,
            color: CupertinoColors.activeBlue,
          ),
          title: Text(
            l10n.personPickerNewNamed(typed),
            style: const TextStyle(
              fontSize: 14,
              color: CupertinoColors.activeBlue,
            ),
          ),
          // Does what it says. It used to only dismiss the keyboard — a
          // row reading "New Person" that makes no person is a button
          // that looks broken, and Save being the real one is not
          // something the row says anywhere.
          onTap: _saving ? null : _save,
        ),
    ];
  }

  Widget _personOption(Person person) => CupertinoListTile(
    key: ValueKey('pick:${person.id}'),
    leading: PersonAvatar.forPerson(
      assetRecordStore: widget.assetRecordStore,
      person: person,
      size: 28,
    ),
    title: Text(person.name, style: const TextStyle(fontSize: 14)),
    onTap: () => setState(() {
      _chosen = person;
      _name.text = person.name;
      _nameFocus.unfocus();
    }),
  );

  /// The same shape a real person page opens with — avatar, name, count —
  /// because that is what this is about to become. The only difference is
  /// that the name is a field you still have to fill in.
  Widget _header(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: switch ((widget.existing, _seed)) {
            (final person?, _) => PersonAvatar.forPerson(
              assetRecordStore: widget.assetRecordStore,
              person: person,
              size: 96,
            ),
            (_, final seed?) => PersonAvatar(
              assetRecordStore: widget.assetRecordStore,
              localId: seed.localId,
              face: seed.face,
              size: 96,
            ),
            _ => const SizedBox(height: 96),
          },
        ),
        const SizedBox(height: 12),
        // Somebody already named has nothing to type: the question is
        // which of these are also them, not what they're called.
        if (widget.existing != null)
          Text(
            widget.existing!.name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          )
        else
          CupertinoSearchTextField(
            controller: _name,
            focusNode: _nameFocus,
            placeholder: l10n.faceGroupNamePlaceholder,
            // Not autofocused: you arrive here to look at the faces and
            // decide, and a keyboard covering them is a dismissal to do
            // before you can answer the question the page is asking.
            onChanged: (_) => setState(() {
              // Typing after picking means they changed their mind about
              // who this is — the field is the answer, not the row.
              _chosen = null;
            }),
          ),
        if (widget.existing == null) ..._nameOptions(l10n),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                _records.length <= 1
                    ? l10n.faceGroupNone
                    : l10n.faceGroupCount(_keptAssets.length),
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.systemGrey,
                ),
              ),
            ),
            if (_records.length > 1)
              CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: _toggleAll,
                child: Text(
                  _allKept
                      ? l10n.faceGroupDeselectAll
                      : l10n.faceGroupSelectAll,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
        ),
        Text(
          l10n.faceGroupHint,
          style: const TextStyle(
            fontSize: 12,
            color: CupertinoColors.systemGrey2,
          ),
        ),
      ],
    ),
  );
}
