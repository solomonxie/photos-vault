import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/library_metadata.dart';
import '../photos/person.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/face_grouping.dart';
import '../photos/face_identity.dart';
import '../photos/person_store.dart';
import '../photos/asset_removal.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'face_group_screen.dart';
import 'asset_grid_view.dart';
import 'asset_picker_screen.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'person_avatar.dart';
import 'person_profile_screen.dart';
import 'zoom_page_route.dart';

/// One person's page: avatar, name (the whole name line opens the full
/// editable profile), and their tagged photos. See DESIGN.md's "People
/// profiles" section and IMPLEMENTATION_PLAN.md T7.3.
class PersonPageScreen extends StatefulWidget {
  /// The name-and-chevron line, which opens the profile.
  static const nameLineKey = Key('personNameLine');

  const PersonPageScreen({
    super.key,
    required this.person,
    required this.personStore,
    required this.assetRecordStore,
    this.aiAnalysisStore,
  });

  final Person person;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  /// Where a confirmed face is looked up when picking a profile photo.
  /// Absent, one is opened on demand — see [faceOfPersonIn].
  final AiAnalysisStore? aiAnalysisStore;

  @override
  State<PersonPageScreen> createState() => _PersonPageScreenState();
}

class _PersonPageScreenState extends State<PersonPageScreen> {
  late Person _person = widget.person;
  List<AssetRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final ids = (await widget.personStore.localIdsIn(_person.id)).toSet();
    final all = await widget.assetRecordStore.listAll();
    if (!mounted) return;
    setState(
      () => _records =
          all.where((r) => !r.isDeleted && ids.contains(r.localId)).toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    );
  }

  Future<void> _openProfile() async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonProfileScreen(
          person: _person,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
    if (!mounted) return;
    // The profile screen persists edits as they're made rather than
    // returning a value — re-fetch, and if it deleted the person, pop this
    // page too (nothing left here to show).
    final refreshed = await widget.personStore.getById(_person.id);
    if (refreshed == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _person = refreshed);
    await _reload();
  }

  Future<void> _addPhotos() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await Navigator.of(context).push<List<AssetRecord>>(
      CupertinoPageRoute(
        builder: (_) => AssetPickerScreen(
          title: l10n.personPageAddPhotos,
          assetRecordStore: widget.assetRecordStore,
          excludeIds: _records.map((r) => r.localId).toSet(),
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    await widget.personStore.addAssets(
      _person.id,
      picked.map((r) => r.localId),
    );
    // Linking a photo is also where somebody with no picture gets one, and
    // the store does that itself — read back rather than second-guess it.
    final refreshed = await widget.personStore.getById(_person.id);
    if (refreshed != null) _person = refreshed;
    await _reload();
  }

  /// Their picture, cropped to nothing in particular: a photo picked whole
  /// carries no face box, so any one left over from a face tapped in a
  /// different photo has to go with it.
  /// Their face in that photo, not the whole photo. It used to write
  /// `avatarFace: null` outright, so picking a picture of two people on a
  /// beach made the beach their portrait.
  Future<void> _setProfilePhoto(AssetRecord record) async {
    final face = await faceOfPersonIn(
      record.localId,
      _person.id,
      analysisStore: widget.aiAnalysisStore,
    );
    await widget.personStore.update(
      _person.copyWith(avatarLocalId: record.localId, avatarFace: () => face),
    );
    // Read back rather than trusting the copy in hand: if the write
    // didn't land, the header should show that instead of the value we
    // hoped for.
    final saved = await widget.personStore.getById(_person.id);
    if (!mounted || saved == null) return;
    setState(() => _person = saved);
  }

  /// Search every photo you haven't named against every face confirmed as
  /// theirs. One tagged face finds photos like that one; forty find
  /// photos like any of them, which is what makes tagging compound rather
  /// than plateau.
  Future<void> _findMore() async {
    final analysisStore = widget.aiAnalysisStore ?? AiAnalysisStore();
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => FaceGroupScreen(
          existing: _person,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
          grouping: FaceGrouping(analysisStore: analysisStore),
          faceIdentity: FaceIdentityService(
            analysisStore: analysisStore,
            resolvePath: (r) async => r.sourcePath,
          ),
        ),
      ),
    );
    await _reload();
  }

  Future<void> _removeFromPerson(AssetRecord record) async {
    await widget.personStore.removeAsset(_person.id, record.localId);
    await _reload();
  }

  /// Deleting is the same decision on every screen: keep the cloud copy
  /// and free the space, or bin it. See `../photos/asset_removal.dart`.
  late final AssetRemoval _removal = AssetRemoval(
    store: widget.assetRecordStore,
  );

  Future<bool> _delete(AssetRecord record) async {
    final outcome = await deleteAsset(
      context,
      record: record,
      removal: _removal,
    );
    await _reload();
    return outcome.leftTheList;
  }

  Future<void> _toggleFavorite(AssetRecord record) async {
    await setFavoriteEverywhere(
      widget.assetRecordStore,
      record,
      !record.isFavorite,
    );
    await _reload();
  }

  void _open(AssetRecord record) {
    Navigator.of(context).push(
      ZoomPageRoute(
        builder: (_) => DetailScreen(
          records: _records,
          initialIndex: _records.indexOf(record),
          onDelete: _delete,
          onToggleFavorite: _toggleFavorite,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(_person.name),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _addPhotos,
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  PersonAvatar.forPerson(
                    assetRecordStore: widget.assetRecordStore,
                    person: _person,
                    firstTaggedLocalId: _records.firstOrNull?.localId,
                    size: 88,
                  ),
                  const SizedBox(height: 8),
                  // The whole line, not the glyphs on it: a bare
                  // `GestureDetector` around a min-width Row is only
                  // hit-testable where something is painted, so the gaps
                  // between the letters — and most of the line — did
                  // nothing, leaving the chevron looking like the only
                  // target.
                  GestureDetector(
                    key: PersonPageScreen.nameLineKey,
                    behavior: HitTestBehavior.opaque,
                    onTap: _openProfile,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              _person.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            CupertinoIcons.chevron_forward,
                            size: 18,
                            color: CupertinoColors.systemGrey,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    onPressed: _findMore,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(CupertinoIcons.search, size: 15),
                        const SizedBox(width: 5),
                        Text(
                          l10n.personPageFindMore,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _records.isEmpty
                  ? Center(
                      child: Text(
                        l10n.personPagePhotosEmpty,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    )
                  : AssetGridView(
                      records: _records,
                      onTap: _open,
                      actionsFor: (r) => [
                        TileAction(
                          icon: r.isFavorite
                              ? CupertinoIcons.heart_slash
                              : CupertinoIcons.heart,
                          label: r.isFavorite
                              ? l10n.libraryUnfavorite
                              : l10n.libraryFavorite,
                          onPressed: () => _toggleFavorite(r),
                        ),
                        TileAction(
                          icon: CupertinoIcons.person_crop_circle,
                          label: l10n.personPageUseAsProfilePhoto,
                          onPressed: () => _setProfilePhoto(r),
                        ),
                        TileAction(
                          icon: CupertinoIcons.person_badge_minus,
                          label: l10n.personPageRemoveFromPerson,
                          onPressed: () => _removeFromPerson(r),
                        ),
                        TileAction(
                          icon: CupertinoIcons.delete,
                          label: l10n.libraryDeleteTooltip,
                          isDestructive: true,
                          onPressed: () => _delete(r),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
