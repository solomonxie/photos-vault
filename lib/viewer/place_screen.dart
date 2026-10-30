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
import 'places_screen.dart';
import 'route_screen.dart';
import 'travel_entry_editor.dart';

/// Photos the library filed under [place]'s name: "Kyoto, Japan" or plain
/// "Kyoto", as `PhotoLocationService` writes them; for a country, every
/// group ending in its name. Countries and cities only: a pin is too small
/// for a town's name to mean it.
List<AssetRecord> photosNamedFor(
  Place place,
  Map<String, List<AssetRecord>> groups,
) {
  final name = place.name.toLowerCase();
  bool matches(String key) => switch (place.kind) {
    PlaceKind.country => key == name || key.endsWith(', $name'),
    PlaceKind.city =>
      key == name ||
          (place.country.isNotEmpty &&
              key == '$name, ${place.country.toLowerCase()}'),
    PlaceKind.area || PlaceKind.point => false,
  };
  return [
    for (final MapEntry(:key, :value) in groups.entries)
      if (matches(key.toLowerCase())) ...value,
  ];
}

/// One place at any level: where it is (the places it's in), its map, the
/// impressions written at it or anywhere inside it, photos, the places
/// inside it and the travel plans through it.
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
  List<Place> _path = const [];
  List<Place> _inside = const [];
  Map<String, Place> _byId = const {};
  Map<String?, List<Place>> _tree = const {};
  PlaceTally _tally = const PlaceTally({}, {});
  List<TravelEntry> _entries = const [];
  Map<String, int> _photosOf = const {};
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
    final places = await store.places();
    final byId = {for (final p in places) p.id: p};
    final place = byId[widget.placeId];
    if (place == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final tree = placeTree(places);
    final below = placeAndBelow(place.id, tree);
    final entries = await store.entriesAtAny(below);
    final counts = await store.entryCountsByPlace();
    final routes = await store.routesThrough(place.id);
    final links = await store.linksFor(LinkOwner.entry, [
      for (final e in entries) e.id,
    ]);
    final path = <Place>[];
    final seen = {place.id};
    for (var up = byId[place.parentId]; up != null; up = byId[up.parentId]) {
      if (!seen.add(up.id)) break;
      path.insert(0, up);
    }
    final inside = tree[place.id] ?? const <Place>[];
    if (!mounted) return;
    setState(() {
      _place = place;
      _path = path;
      _inside = inside;
      _byId = byId;
      _tree = tree;
      _tally = PlaceTally.of(tree, counts);
      _entries = entries;
      _routes = routes;
      _named = photosNamedFor(place, widget.placeGroups);
      _photosOf = {
        for (final MapEntry(:key, :value) in links.entries)
          key: value.where((l) => l.target == LinkTarget.asset).length,
      };
      _linkedPhotos = {
        for (final list in links.values)
          for (final l in list)
            if (l.target == LinkTarget.asset) l.id,
      };
      _pins = [
        if (!place.isCountry || inside.isEmpty)
          MapPinData(
            id: place.id,
            lat: place.lat,
            lng: place.lng,
            title: place.name,
          ),
        for (final p in inside)
          MapPinData(id: p.id, lat: p.lat, lng: p.lng, title: p.name),
      ];
    });
  }

  Future<void> _write() async {
    final place = _place;
    if (place == null) return;
    final changed = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => TravelEntryEditor(
          travelStore: widget.travelStore,
          entry: widget.travelStore.newEntry(
            placeId: place.id,
            kind: EntryKind.impression,
          ),
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
          placeName: _byId[e.placeId]?.name ?? _place?.name ?? '',
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

  Future<void> _addInside() async {
    final place = _place;
    if (place == null) return;
    final added = await showAddPlaceSheet(
      context: context,
      travelStore: widget.travelStore,
      placeSearch: widget.placeSearch,
      under: place,
    );
    if (added == null || !mounted) return;
    await _openPlace(added.id);
  }

  Future<void> _dropPin(double lat, double lng) async {
    final place = _place;
    if (place == null) return;
    final added = await dropPlacePin(
      context: context,
      travelStore: widget.travelStore,
      placeSearch: widget.placeSearch,
      lat: lat,
      lng: lng,
      under: place,
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
            key: const ValueKey('placeMove'),
            onPressed: () => Navigator.of(sheet).pop('move'),
            child: Text(l10n.placeMove),
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
      case 'move':
        await _move();
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

  /// Into another place, or to the top: anywhere but itself and what's
  /// inside it.
  Future<void> _move() async {
    final place = _place;
    if (place == null) return;
    final l10n = AppLocalizations.of(context)!;
    final mine = placeAndBelow(place.id, _tree);
    final rows = <(Place, int)>[];
    void walk(String? parent, int depth) {
      for (final p in _tree[parent] ?? const <Place>[]) {
        if (mine.contains(p.id)) continue;
        rows.add((p, depth));
        walk(p.id, depth + 1);
      }
    }

    walk(null, 0);
    const top = '';
    final picked = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheet) => CupertinoPopupSurface(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * 0.7,
          child: SafeArea(
            top: false,
            child: ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l10n.placeMoveTitle(place.name),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                CupertinoListTile(
                  key: const ValueKey('placeMoveTop'),
                  leading: const Icon(CupertinoIcons.globe),
                  title: Text(l10n.placeMoveToTop),
                  onTap: () => Navigator.of(sheet).pop(top),
                ),
                for (final (p, depth) in rows)
                  CupertinoListTile(
                    key: ValueKey('placeMoveTo-${p.id}'),
                    padding: EdgeInsetsDirectional.only(
                      start: 20.0 + depth * 20,
                      end: 14,
                    ),
                    leading: Icon(placeIcon(p.kind)),
                    title: Text(p.name),
                    trailing: p.id == place.parentId
                        ? const Icon(CupertinoIcons.check_mark)
                        : null,
                    onTap: () => Navigator.of(sheet).pop(p.id),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null) return;
    final parent = picked == top ? null : picked;
    if (parent == place.parentId) return;
    await widget.travelStore.updatePlace(
      place.copyWith(parentId: () => parent),
    );
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
    const grey = TextStyle(color: CupertinoColors.systemGrey);
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
                    height: 200,
                    child: NativeMap(
                      pins: _pins,
                      onPinTap: _openPlace,
                      onLongPress: _dropPin,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_path.isNotEmpty)
                          Wrap(
                            key: const ValueKey('placePath'),
                            children: [
                              for (final (i, p) in _path.indexed) ...[
                                if (i > 0) const Text(' › ', style: grey),
                                GestureDetector(
                                  key: ValueKey('placePath-${p.id}'),
                                  onTap: () => _openPlace(p.id),
                                  child: Text(
                                    p.name,
                                    style: const TextStyle(
                                      color: CupertinoColors.activeBlue,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        Text(
                          place.name,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          [
                            placeKindLabel(l10n, place.kind),
                            if (place.category.isNotEmpty) place.category,
                            if (place.address.isNotEmpty) place.address,
                          ].join(' · '),
                          style: grey,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: CupertinoButton.tinted(
                      key: const ValueKey('placeAddImpression'),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      onPressed: _write,
                      child: Text(l10n.placeAddImpression),
                    ),
                  ),
                  if (_entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                      child: Text(l10n.placeNoEntries, style: grey),
                    )
                  else
                    CupertinoListSection.insetGrouped(
                      header: Text(l10n.placeImpressions),
                      children: [
                        for (final e in _entries)
                          impressionTile(
                            l10n,
                            e,
                            at: e.placeId == place.id
                                ? null
                                : _byId[e.placeId]?.name,
                            photos: _photosOf[e.id] ?? 0,
                            onTap: () => _read(e),
                          ),
                      ],
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
                  CupertinoListSection.insetGrouped(
                    header: Text(l10n.placePoints(place.name)),
                    children: [
                      for (final p in _inside)
                        placeTile(
                          l10n,
                          p,
                          _tally,
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
                        onTap: _addInside,
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
}

/// An impression in a list: its title (or first line), the day, rating,
/// where inside the page's place it was written ([at]) and its photos.
Widget impressionTile(
  AppLocalizations l10n,
  TravelEntry e, {
  String? at,
  int photos = 0,
  required VoidCallback onTap,
}) {
  final excerpt = e.text.trim().split('\n').first;
  final line = [
    if (at != null) l10n.impressionAt(at),
    if (travelEntryLine(e) case final l when l.isNotEmpty) l,
    if (photos > 0) l10n.travelEntryPhotosCount(photos),
  ].join(' · ');
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
    onTap: onTap,
  );
}
