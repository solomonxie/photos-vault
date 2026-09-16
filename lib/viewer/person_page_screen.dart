import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/library_metadata.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
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
  });

  final Person person;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

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
    if (_person.avatarLocalId == null) {
      final updated = _person.copyWith(avatarLocalId: picked.first.localId);
      await widget.personStore.update(updated);
      _person = updated;
    }
    await _reload();
  }

  Future<void> _removeFromPerson(AssetRecord record) async {
    await widget.personStore.removeAsset(_person.id, record.localId);
    await _reload();
  }

  Future<bool> _delete(AssetRecord record) async {
    if (!await confirmSoftDelete(context)) return false;
    await widget.assetRecordStore.softDelete(record.localId);
    await _reload();
    return true;
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
                  PersonAvatar(
                    assetRecordStore: widget.assetRecordStore,
                    localId: _person.avatarLocalId,
                    face: _person.avatarFace,
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
