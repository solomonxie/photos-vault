import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/person.dart';
import '../photos/face_grouping.dart';
import '../photos/face_identity.dart';
import '../photos/person_store.dart';
import '../photos/unnamed_faces.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';
import 'face_group_screen.dart';
import 'person_picker_sheet.dart';
import 'person_profile_screen.dart';
import 'smart_collection_screen.dart';

/// Collections' "People" row: named [Person] profiles (T7.1-T7.3), each with
/// a photo count, plus a link down to the older AI people-*count* grouping
/// for finding more faces to name. See IMPLEMENTATION_PLAN.md Phase 7.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({
    super.key,
    required this.personStore,
    required this.assetRecordStore,
    this.aiAnalysisStore,
    this.faceIdentity,
  });

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;
  final AiAnalysisStore? aiAnalysisStore;

  /// Remembers a face once it's named, so the next photo of them can be
  /// guessed. Absent, naming still works — it just teaches nothing.
  final FaceIdentityService? faceIdentity;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  List<Person> _people = const [];
  Map<String, int> _counts = const {};
  Map<String, String> _firstPhoto = const {};
  List<UnnamedFace> _unnamedFaces = const [];

  /// How many there are altogether — [_unnamedFaces] is the first twenty.
  /// Without it the section reads the same whether the scan has found
  /// twenty faces or four hundred.
  int _facesFound = 0;
  String _query = '';

  /// This is the page you open to work through them, so it shows far more
  /// than the home row's handful. Each one is a person, not a face, and
  /// they are ordered biggest pile first — so a list this long is mostly
  /// a long tail of one-offs below the names worth giving.
  static const _unnamedFacesShown = 60;

  /// One size for every circle on this page. A named person and a face
  /// waiting for a name are the same kind of thing asked from two sides,
  /// and drawing them at two scales made the list look like two lists.
  static const _faceSize = 66.0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final people = await widget.personStore.listAll();
    final counts = <String, int>{};
    final firstPhoto = <String, String>{};
    final tagged = <String>{};
    for (final person in people) {
      final localIds = await widget.personStore.localIdsIn(person.id);
      counts[person.id] = localIds.length;
      tagged.addAll(localIds);
      if (localIds.isNotEmpty) firstPhoto[person.id] = localIds.first;
    }
    final unnamed = await _loadUnnamedFaces(tagged, {
      for (final p in people) p.id: p.name,
    });
    // Most photographed first, matching the faces below it. This is a
    // list for working through, and the person you have four hundred
    // photos of is the one you came here about.
    people.sort((a, b) => (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0));
    if (!mounted) return;
    setState(() {
      _people = people;
      _counts = counts;
      _firstPhoto = firstPhoto;
      _unnamedFaces = unnamed.faces;
      _facesFound = unnamed.found;
    });
  }

  /// The same strangers the home page's People row offers, on the page
  /// that row's "More" leads to — naming somebody is the one thing you
  /// come here to do, and sending you back to the home screen to do it was
  /// the wrong way round.
  Future<UnnamedFaces> _loadUnnamedFaces(
    Set<String> tagged,
    Map<String, String> peopleById,
  ) async {
    final analysisStore = widget.aiAnalysisStore;
    if (analysisStore == null) return (faces: const <UnnamedFace>[], found: 0);
    try {
      return await findUnnamedFaces(
        analysisStore: analysisStore,
        records: await widget.assetRecordStore.listAll(),
        taggedLocalIds: tagged,
        peopleById: peopleById,
        limit: _unnamedFacesShown,
      );
    } catch (_) {
      // No record database to read (a widget test, no platform channel) —
      // the page is still the list of people, which is what it's for.
      return (faces: const <UnnamedFace>[], found: 0);
    }
  }

  /// Opens the face as a person who doesn't exist yet — their photos
  /// gathered, nothing written down until a name is given. Falls back to
  /// the picker when there's no grouping to show, which is what "add this
  /// face to somebody I've already named" needs anyway.
  Future<void> _nameFace(UnnamedFace face) async {
    final analysisStore = widget.aiAnalysisStore;
    final identity = widget.faceIdentity;
    if (analysisStore == null || identity == null) {
      final picked = await nameFace(
        context: context,
        personStore: widget.personStore,
        face: face,
        identity: identity,
        assetRecordStore: widget.assetRecordStore,
      );
      if (picked != null && mounted) await _reload();
      return;
    }
    final created = await Navigator.of(context).push<Person>(
      CupertinoPageRoute(
        builder: (_) => FaceGroupScreen(
          seed: face,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
          grouping: FaceGrouping(analysisStore: analysisStore),
          faceIdentity: identity,
        ),
      ),
    );
    if (created != null && mounted) await _reload();
  }

  /// The other question about a face: "this is somebody I already named."
  /// Kept as the ✓ row action, where the app has a guess to confirm.
  Future<void> _pickPersonFor(UnnamedFace face) async {
    final picked = await nameFace(
      context: context,
      personStore: widget.personStore,
      face: face,
      identity: widget.faceIdentity,
      assetRecordStore: widget.assetRecordStore,
    );
    if (picked != null && mounted) await _reload();
  }

  /// One tap, because the app already has a name for this face and the row
  /// is showing it. Undoable, for exactly that reason.
  Future<void> _acceptSuggestion(UnnamedFace face) async {
    final personId = face.suggestedPersonId;
    final name = face.suggestedName;
    if (personId == null || name == null) return;
    final l10n = AppLocalizations.of(context)!;
    await widget.personStore.addAssets(personId, [face.localId]);
    final identity = widget.faceIdentity;
    if (identity != null) {
      final record = await widget.assetRecordStore.getByLocalId(face.localId);
      if (record != null) {
        await identity.remember(
          record: record,
          face: face.face,
          personId: personId,
        );
      }
    }
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    _showUndo(l10n.peopleSuggestionAccepted(name), () async {
      await widget.personStore.removeAsset(personId, face.localId);
      // The descriptor goes back too. Undo that only unlinked the photo
      // would leave the face in the reference set, pulling later photos
      // towards the person just rejected.
      await identity?.unremember(localId: face.localId, face: face.face);
      if (mounted) await _reload();
    });
  }

  /// The toast's own auto-dismiss. Held so leaving the page takes it with
  /// us — a timer that fires into a disposed tree is a crash waiting for
  /// whoever navigates away inside five seconds.
  Timer? _undoTimer;
  OverlayEntry? _undoToast;

  @override
  void dispose() {
    _undoTimer?.cancel();
    _undoToast?.remove();
    _undoToast = null;
    super.dispose();
  }

  void _showUndo(String message, Future<void> Function() undo) {
    final l10n = AppLocalizations.of(context)!;
    final overlay = Overlay.of(context);
    // One at a time: accepting two guesses quickly should leave one toast
    // about the second, not two stacked on the same spot.
    _undoTimer?.cancel();
    _undoToast?.remove();
    late final OverlayEntry entry;
    var dismissed = false;
    void close() {
      if (dismissed) return;
      dismissed = true;
      _undoTimer?.cancel();
      if (identical(_undoToast, entry)) _undoToast = null;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).padding.bottom + 24,
        child: CupertinoPopupSurface(
          isSurfacePainted: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Expanded(child: Text(message, maxLines: 1)),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: Size.zero,
                  onPressed: () {
                    close();
                    unawaited(undo());
                  },
                  child: Text(l10n.actionUndo),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    _undoToast = entry;
    _undoTimer = Timer(const Duration(seconds: 5), close);
  }

  /// Rows, not the home page's horizontal strip. This is the full list —
  /// the page you come to when you mean to work through them — and a
  /// sideways scroll inside a vertical one hides most of its contents
  /// behind a gesture nobody makes on a settings-shaped page.
  List<Widget> _unnamedFaceRows(AppLocalizations l10n) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.peopleUnnamedHeading,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          // The list is the first twenty; this is how many there are.
          // Without it the section reads the same whether the scan has
          // found twenty faces or four hundred.
          Text(
            '$_facesFound',
            style: const TextStyle(
              fontSize: 13,
              color: CupertinoColors.systemGrey,
            ),
          ),
        ],
      ),
    ),
    for (final face in _unnamedFaces)
      CupertinoListTile(
        key: ValueKey('face:${face.localId}:${face.face.encode()}'),
        // `CupertinoListTile` clamps its leading widget to 28pt unless
        // told otherwise, so every size set on the avatar below was being
        // thrown away. That, not the avatar, is why these stayed tiny.
        leadingSize: _faceSize + 4,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        // Much bigger than a named person's 44pt row avatar, deliberately:
        // that one is a reminder of somebody you know, this one is the
        // whole question. A face cropped out of a photo is a small patch
        // of it to begin with — at 40 and again at 64 there wasn't enough
        // of it to answer "who is this?" from, so the row is as tall as
        // the face needs rather than as short as a list row usually is.
        leading: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: CupertinoColors.systemGrey, width: 1.5),
          ),
          padding: const EdgeInsets.all(2),
          child: PersonAvatar(
            assetRecordStore: widget.assetRecordStore,
            localId: face.localId,
            face: face.face,
            size: _faceSize,
          ),
        ),
        title: Text(
          face.hasSuggestion
              ? l10n.peopleSuggestedFace(face.suggestedName!)
              : l10n.peopleUnnamedFace,
          style: const TextStyle(color: CupertinoColors.systemGrey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // How many faces this circle stands for. Reads like a named
            // person's photo count, because it is about to become one.
            if (face.alike > 1)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '${face.alike}',
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              ),
            // Two different questions, so two different controls. The
            // row asks "who is this?" and opens the group. This asks the
            // narrower one: ✓ where the app already has a name to
            // confirm, otherwise "add this face to somebody I've named".
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(44, 44),
              onPressed: face.hasSuggestion
                  ? () => _acceptSuggestion(face)
                  : () => _pickPersonFor(face),
              child: Icon(
                face.hasSuggestion
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.person_crop_circle_badge_plus,
                size: 24,
                color: CupertinoColors.activeBlue,
              ),
            ),
            const Icon(
              CupertinoIcons.chevron_forward,
              size: 18,
              color: CupertinoColors.systemGrey2,
            ),
          ],
        ),
        onTap: () => _nameFace(face),
      ),
  ];

  /// Straight to the profile with the keyboard in the name field, rather
  /// than a dialog asking for a name and then a page asking for everything
  /// else. The person is real from the first keystroke — the profile
  /// writes each field as it's typed, and there is nothing here that a
  /// "Save" button would do.
  ///
  /// Leaving the name blank is how you back out: a nameless person is one
  /// nobody started, so it's dropped on the way out rather than left in
  /// the list as an untitled row.
  Future<void> _addPerson() async {
    final person = await widget.personStore.create(name: '');
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonProfileScreen(
          person: person,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
          autofocusName: true,
        ),
      ),
    );
    final saved = await widget.personStore.getById(person.id);
    if ((saved?.name ?? '').trim().isEmpty) {
      await widget.personStore.remove(person.id);
      await widget.faceIdentity?.forget(person.id);
    }
    if (!mounted) return;
    await _reload();
  }

  void _openPerson(Person person) {
    Navigator.of(context)
        .push(
          CupertinoPageRoute(
            builder: (_) => PersonPageScreen(
              person: person,
              personStore: widget.personStore,
              assetRecordStore: widget.assetRecordStore,
            ),
          ),
        )
        .then((_) => _reload());
  }

  void _openAiAnalysis() {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => SmartCollectionScreen(
          kind: SmartCollectionKind.people,
          assetRecordStore: widget.assetRecordStore,
          aiAnalysisStore: widget.aiAnalysisStore,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _people
        : _people.where((p) => p.name.toLowerCase().contains(query)).toList();
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.peopleScreenTitle),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _addPerson,
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            if (_people.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: CupertinoSearchTextField(
                  // Not autofocused: the page is a list you came to read,
                  // and a keyboard covering half of it on arrival is a
                  // dismissal to do before you can look at anything.
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            if (_people.isEmpty && _unnamedFaces.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 48),
                child: Center(
                  child: Text(
                    l10n.peopleEmpty,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                ),
              )
            else if (_people.isNotEmpty && filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 48),
                child: Center(
                  child: Text(
                    l10n.peopleSearchEmpty,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                ),
              )
            else
              for (final person in filtered)
                CupertinoListTile(
                  key: ValueKey(person.id),
                  // Same size as the faces below, and for the same
                  // reason: `CupertinoListTile` clamps its leading widget
                  // to 28pt unless told, so a named person's 44 was being
                  // thrown away and the two halves of one list were
                  // drawn at two different scales.
                  leadingSize: _faceSize + 4,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  leading: PersonAvatar.forPerson(
                    assetRecordStore: widget.assetRecordStore,
                    person: person,
                    firstTaggedLocalId: _firstPhoto[person.id],
                    size: _faceSize,
                  ),
                  title: Text(person.name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${_counts[person.id] ?? 0}',
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        CupertinoIcons.chevron_forward,
                        size: 18,
                        color: CupertinoColors.systemGrey2,
                      ),
                    ],
                  ),
                  onTap: () => _openPerson(person),
                ),
            if (_unnamedFaces.isNotEmpty && query.isEmpty)
              ..._unnamedFaceRows(l10n),
            const SizedBox(height: 16),
            CupertinoListTile(
              leading: const Icon(
                CupertinoIcons.sparkles,
                color: CupertinoColors.systemIndigo,
              ),
              title: Text(l10n.peopleAiAnalysisRow),
              trailing: const Icon(
                CupertinoIcons.chevron_forward,
                size: 18,
                color: CupertinoColors.systemGrey2,
              ),
              onTap: _openAiAnalysis,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
