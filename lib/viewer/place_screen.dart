import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_group_screen.dart';
import 'native_map.dart';
import 'route_screen.dart';
import 'travel_entry_editor.dart';
import 'travel_screen.dart';

/// Photos the library filed under [place]'s name: "Kyoto, Japan" or plain
/// "Kyoto", as `PhotoLocationService` writes them. Cities only; a point is
/// too small for a town's name to mean it.
List<AssetRecord> photosNamedFor(
  Place place,
  Map<String, List<AssetRecord>> groups,
) {
  if (!place.isCity) return const [];
  final names = {
    place.name.toLowerCase(),
    if (place.country.isNotEmpty)
      '${place.name}, ${place.country}'.toLowerCase(),
  };
  return [
    for (final MapEntry(:key, :value) in groups.entries)
      if (names.contains(key.toLowerCase())) ...value,
  ];
}

/// One place: its map, impressions (one per visit), diary, photos taken
/// there, the places inside it and the routes through it.
class PlaceScreen extends StatefulWidget {
  const PlaceScreen({
    super.key,
    required this.travelStore,
    required this.placeSearch,
    required this.placeId,
    this.assetRecordStore,
    this.personStore,
    this.placeGroups = const {},
  });

  final TravelStore travelStore;
  final PlaceSearch placeSearch;
  final String placeId;
  final AssetRecordStore? assetRecordStore;
  final PersonStore? personStore;

  /// The library's photos by place name; see [photosNamedFor].
  final Map<String, List<AssetRecord>> placeGroups;

  @override
  State<PlaceScreen> createState() => _PlaceScreenState();
}

class _PlaceScreenState extends State<PlaceScreen> {
  Place? _place;
  Place? _city;
  List<TravelEntry> _impressions = const [];
  List<TravelEntry> _diary = const [];
  List<Place> _points = const [];
  List<TravelRoute> _routes = const [];
  List<MapPinData> _pins = const [];
  List<AssetRecord> _named = const [];
  Set<String> _linkedPhotos = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = widget.travelStore;
    final place = await store.place(widget.placeId);
    if (place == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final entries = await store.entriesAt(place.id);
    final points = place.isCity
        ? await store.placesIn(place.id)
        : const <Place>[];
    final city = place.parentId == null
        ? null
        : await store.place(place.parentId!);
    final routes = await store.routesThrough(place.id);
    final links = await store.linksFor(LinkOwner.entry, [
      for (final e in entries) e.id,
    ]);
    if (!mounted) return;
    setState(() {
      _place = place;
      _city = city;
      _impressions = [
        for (final e in entries)
          if (e.kind == EntryKind.impression) e,
      ];
      _diary = [
        for (final e in entries)
          if (e.kind == EntryKind.diary) e,
      ];
      _points = points;
      _routes = routes;
      _named = photosNamedFor(place, widget.placeGroups);
      _linkedPhotos = {
        for (final list in links.values)
          for (final l in list)
            if (l.target == LinkTarget.asset) l.id,
      };
      _pins = [
        MapPinData(
          id: place.id,
          lat: place.lat,
          lng: place.lng,
          title: place.name,
        ),
        for (final p in points)
          MapPinData(id: p.id, lat: p.lat, lng: p.lng, title: p.name),
      ];
    });
  }

  Future<void> _write(EntryKind kind) async {
    final place = _place;
    if (place == null) return;
    final changed = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => TravelEntryEditor(
          travelStore: widget.travelStore,
          entry: widget.travelStore.newEntry(placeId: place.id, kind: kind),
          placeName: place.name,
          isNew: true,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
        ),
      ),
    );
    if (changed == true) await _load();
  }

  Future<void> _read(TravelEntry e) async {
    final changed = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => TravelEntryScreen(
          travelStore: widget.travelStore,
          entryId: e.id,
          placeName: _place?.name ?? '',
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
        ),
      ),
    );
    if (changed == true) await _load();
  }

  Future<void> _openPlace(String id) async {
    if (id == widget.placeId) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PlaceScreen(
          travelStore: widget.travelStore,
          placeSearch: widget.placeSearch,
          placeId: id,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
          placeGroups: widget.placeGroups,
        ),
      ),
    );
    await _load();
  }

  Future<void> _openRoute(TravelRoute r) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => RouteScreen(
          travelStore: widget.travelStore,
          placeSearch: widget.placeSearch,
          routeId: r.id,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
        ),
      ),
    );
    await _load();
  }

  Future<void> _openPhotos() async {
    final store = widget.assetRecordStore;
    final place = _place;
    if (store == null || place == null) return;
    final linked = await store.listOf(_linkedPhotos);
    final seen = {for (final r in linked) r.localId};
    final records = [
      ...linked,
      for (final r in _named)
        if (!seen.contains(r.localId)) r,
    ];
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => AssetGroupScreen(
          title: place.name,
          records: records,
          assetRecordStore: store,
          travelStore: widget.travelStore,
        ),
      ),
    );
  }

  Future<void> _addPoint() async {
    final place = _place;
    if (place == null) return;
    final added = await showAddPlaceSheet(
      context: context,
      travelStore: widget.travelStore,
      placeSearch: widget.placeSearch,
      near: place,
    );
    if (added == null || !mounted) return;
    await _openPlace(added.id);
  }

  Future<void> _more() async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(_place?.name ?? ''),
        actions: [
          CupertinoActionSheetAction(
            key: const ValueKey('placeRename'),
            onPressed: () => Navigator.of(sheet).pop('rename'),
            child: Text(l10n.placeRename),
          ),
          CupertinoActionSheetAction(
            key: const ValueKey('placeDelete'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(sheet).pop('delete'),
            child: Text(l10n.placeDelete),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'rename':
        await _rename();
      case 'delete':
        await _delete();
    }
  }

  Future<void> _rename() async {
    final place = _place;
    if (place == null) return;
    final l10n = AppLocalizations.of(context)!;
    final name = TextEditingController(text: place.name);
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(l10n.placeRename),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: CupertinoTextField(
            key: const ValueKey('placeRenameField'),
            controller: name,
            autofocus: true,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('placeRenameSave'),
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.travelEntrySave),
          ),
        ],
      ),
    );
    final typed = name.text.trim();
    name.dispose();
    if (ok != true || typed.isEmpty || typed == place.name) return;
    await widget.travelStore.updatePlace(place.copyWith(name: typed));
    await _load();
  }

  Future<void> _delete() async {
    final place = _place;
    if (place == null) return;
    final l10n = AppLocalizations.of(context)!;
    final deleted = await widget.travelStore.deletePlace(place.id);
    if (!mounted) return;
    if (deleted) {
      Navigator.of(context).pop();
      return;
    }
    await showCupertinoDialog<void>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        key: const ValueKey('placeDeleteInUse'),
        content: Text(l10n.placeDeleteInUse),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(l10n.travelEntryDone),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final place = _place;
    final photos = _linkedPhotos.length + _named.length;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(place?.name ?? ''),
        trailing: CupertinoButton(
          key: const ValueKey('placeMore'),
          padding: EdgeInsets.zero,
          onPressed: place == null ? null : _more,
          child: const Icon(CupertinoIcons.ellipsis_circle),
        ),
      ),
      child: place == null
          ? const Center(child: CupertinoActivityIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  SizedBox(
                    height: 180,
                    child: NativeMap(
                      pins: _pins,
                      interactive: false,
                      onPinTap: _openPlace,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place.name,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (_city case final city?)
                          GestureDetector(
                            key: const ValueKey('placeCity'),
                            onTap: () => _openPlace(city.id),
                            child: Text(
                              l10n.placeInCity(city.name),
                              style: const TextStyle(
                                color: CupertinoColors.activeBlue,
                              ),
                            ),
                          )
                        else if (place.country.isNotEmpty)
                          Text(
                            place.country,
                            style: const TextStyle(
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: CupertinoButton.tinted(
                            key: const ValueKey('placeWriteDiary'),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            onPressed: () => _write(EntryKind.diary),
                            child: Text(l10n.placeWriteDiary),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: CupertinoButton.tinted(
                            key: const ValueKey('placeAddImpression'),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            onPressed: () => _write(EntryKind.impression),
                            child: Text(l10n.placeAddImpression),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_impressions.isNotEmpty)
                    CupertinoListSection.insetGrouped(
                      header: Text(l10n.placeImpressions),
                      children: [
                        for (final e in _impressions) _entryTile(l10n, e),
                      ],
                    ),
                  if (_diary.isNotEmpty)
                    CupertinoListSection.insetGrouped(
                      header: Text(l10n.placeDiary),
                      children: [for (final e in _diary) _entryTile(l10n, e)],
                    ),
                  if (_impressions.isEmpty && _diary.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                      child: Text(
                        l10n.placeNoEntries,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    ),
                  if (photos > 0 && widget.assetRecordStore != null)
                    CupertinoListSection.insetGrouped(
                      children: [
                        CupertinoListTile(
                          key: const ValueKey('placePhotos'),
                          leading: const Icon(
                            CupertinoIcons.photo_on_rectangle,
                          ),
                          title: Text(l10n.placePhotosHere),
                          additionalInfo: Text('$photos'),
                          trailing: const CupertinoListTileChevron(),
                          onTap: _openPhotos,
                        ),
                      ],
                    ),
                  if (place.isCity)
                    CupertinoListSection.insetGrouped(
                      header: Text(l10n.placePoints(place.name)),
                      children: [
                        for (final p in _points)
                          CupertinoListTile(
                            key: ValueKey('placePoint-${p.id}'),
                            leading: const Icon(
                              CupertinoIcons.map_pin,
                              color: CupertinoColors.systemTeal,
                            ),
                            title: Text(p.name),
                            trailing: const CupertinoListTileChevron(),
                            onTap: () => _openPlace(p.id),
                          ),
                        CupertinoListTile(
                          key: const ValueKey('placeAddPoint'),
                          leading: const Icon(
                            CupertinoIcons.add_circled,
                            color: CupertinoColors.activeBlue,
                          ),
                          title: Text(
                            l10n.placeAddPoint,
                            style: const TextStyle(
                              color: CupertinoColors.activeBlue,
                            ),
                          ),
                          onTap: _addPoint,
                        ),
                      ],
                    ),
                  if (_routes.isNotEmpty)
                    CupertinoListSection.insetGrouped(
                      header: Text(l10n.placeRoutesThrough),
                      children: [
                        for (final r in _routes)
                          CupertinoListTile(
                            key: ValueKey('placeRoute-${r.id}'),
                            leading: const Icon(
                              CupertinoIcons.arrow_branch,
                              color: CupertinoColors.systemIndigo,
                            ),
                            title: Text(r.title),
                            trailing: const CupertinoListTileChevron(),
                            onTap: () => _openRoute(r),
                          ),
                      ],
                    ),
                ],
              ),
            ),
    );
  }

  Widget _entryTile(AppLocalizations l10n, TravelEntry e) {
    final line = travelEntryLine(e);
    final excerpt = e.text.trim().split('\n').first;
    return CupertinoListTile(
      key: ValueKey('placeEntry-${e.id}'),
      title: Text(
        e.title.isNotEmpty
            ? e.title
            : (excerpt.isNotEmpty ? excerpt : l10n.travelEntryUntitled),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: line.isEmpty
          ? null
          : Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const CupertinoListTileChevron(),
      onTap: () => _read(e),
    );
  }
}
