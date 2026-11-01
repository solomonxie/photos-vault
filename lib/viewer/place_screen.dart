import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
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

/// Photos taken within [place]'s reach of it: a pin's own spot, so its page
/// shows a narrower set than its city's.
List<AssetRecord> photosNear(
  Place place,
  Map<String, List<AssetRecord>> groups,
) {
  final reach = place.kind == PlaceKind.area ? 1500.0 : 300.0;
  final cosLat = math.cos(place.lat * math.pi / 180);
  const metresPerDegree = 111320.0;
  final seen = <String>{};
  return [
    for (final list in groups.values)
      for (final r in list)
        if ((r.latitude, r.longitude) case (final la?, final lo?)
            when (la - place.lat).abs() * metresPerDegree < reach &&
                math.sqrt(
                      math.pow((la - place.lat) * metresPerDegree, 2) +
                          math.pow(
                            (lo - place.lng) * metresPerDegree * cosLat,
                            2,
                          ),
                    ) <
                    reach &&
                seen.add(r.localId))
          r,
  ];
}

/// One place at any level, pin or country alike: its description, the pins
/// inside it, the impressions written at it or anywhere inside it, the
/// travel plans through it, and its photos, folded, at the bottom.
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

  /// Linked to its impressions, then taken there; newest first.
  List<AssetRecord> _photos = const [];
  bool _photosOpen = false;

  static const _photoPreview = 12;

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
    final linkedIds = {
      for (final list in links.values)
        for (final l in list)
          if (l.target == LinkTarget.asset) l.id,
    };
    final linked = linkedIds.isEmpty
        ? const <AssetRecord>[]
        : await widget.assetRecordStore?.listOf(linkedIds) ??
              const <AssetRecord>[];
    final seenPhotos = {for (final r in linked) r.localId};
    final here = switch (place.kind) {
      PlaceKind.country ||
      PlaceKind.city => photosNamedFor(place, widget.placeGroups),
      PlaceKind.area ||
      PlaceKind.point => photosNear(place, widget.placeGroups),
    };
    final photos = [
      ...linked,
      for (final r in here)
        if (seenPhotos.add(r.localId)) r,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
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
      _photos = photos;
      _photosOf = {
        for (final MapEntry(:key, :value) in links.entries)
          key: value.where((l) => l.target == LinkTarget.asset).length,
      };
      _pins = [
        if (_isPin(place))
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
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => AssetGroupScreen(
          title: place.name,
          records: _photos,
          assetRecordStore: store,
          travelStore: widget.travelStore,
        ),
      ),
    );
  }

  Future<void> _editDescription() async {
    final place = _place;
    if (place == null) return;
    final l10n = AppLocalizations.of(context)!;
    final text = TextEditingController(text: place.description);
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(l10n.placeDescriptionTitle),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: CupertinoTextField(
            key: const ValueKey('placeDescriptionField'),
            controller: text,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('placeDescriptionSave'),
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.travelEntrySave),
          ),
        ],
      ),
    );
    final typed = text.text.trim();
    text.dispose();
    if (ok != true || typed == place.description) return;
    await widget.travelStore.updatePlace(place.copyWith(description: typed));
    await _load();
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

  static bool _isPin(Place p) =>
      p.kind == PlaceKind.point || p.kind == PlaceKind.area;

  /// What the map shows with nothing pinned: the whole country or city.
  static ({double lat, double lng, double span}) _regionOf(Place p) => (
    lat: p.lat,
    lng: p.lng,
    span: switch (p.kind) {
      PlaceKind.country => 14,
      PlaceKind.city => 0.25,
      PlaceKind.area => 0.03,
      PlaceKind.point => 0.01,
    },
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final place = _place;
    const grey = TextStyle(color: CupertinoColors.systemGrey, fontSize: 15);
    const blue = TextStyle(color: CupertinoColors.activeBlue, fontSize: 15);
    Widget addRow(Key key, String label, VoidCallback onTap) =>
        CupertinoListTile(
          key: key,
          leading: const Icon(
            CupertinoIcons.add_circled,
            color: CupertinoColors.activeBlue,
          ),
          title: Text(
            label,
            style: const TextStyle(color: CupertinoColors.activeBlue),
          ),
          onTap: onTap,
        );
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        height: 170,
                        child: NativeMap(
                          pins: _pins,
                          region: _regionOf(place),
                          onPinTap: _openPlace,
                          onLongPress: _isPin(place) ? null : _dropPin,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
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
                                  child: Text(p.name, style: blue),
                                ),
                              ],
                            ],
                          ),
                        const SizedBox(height: 2),
                        Text(
                          place.name,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
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
                  CupertinoListSection.insetGrouped(
                    children: [
                      place.description.isEmpty
                          ? CupertinoListTile(
                              key: const ValueKey('placeDescription'),
                              leading: const Icon(
                                CupertinoIcons.text_alignleft,
                                color: CupertinoColors.systemGrey,
                              ),
                              title: Text(
                                l10n.placeDescriptionAdd,
                                style: const TextStyle(
                                  color: CupertinoColors.systemGrey,
                                ),
                              ),
                              onTap: _editDescription,
                            )
                          : GestureDetector(
                              key: const ValueKey('placeDescription'),
                              behavior: HitTestBehavior.opaque,
                              onTap: _editDescription,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  12,
                                  20,
                                  12,
                                ),
                                child: Text(
                                  place.description,
                                  style: const TextStyle(height: 1.35),
                                ),
                              ),
                            ),
                    ],
                  ),
                  // A pin holds no pins; an area from before pins replaced
                  // areas still lists what was filed in it.
                  if (!_isPin(place) || _inside.isNotEmpty)
                    CupertinoListSection.insetGrouped(
                      header: Text(
                        place.isCountry
                            ? l10n.footprintsPlaces
                            : l10n.placePins,
                      ),
                      children: [
                        for (final p in _inside)
                          placeTile(
                            l10n,
                            p,
                            _tally,
                            onTap: () => _openPlace(p.id),
                          ),
                        if (!_isPin(place))
                          addRow(
                            const ValueKey('placeAddPoint'),
                            l10n.placeAddPoint,
                            _addInside,
                          ),
                      ],
                    ),
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
                      addRow(
                        const ValueKey('placeAddImpression'),
                        l10n.placeAddImpression,
                        _write,
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
                  if (_photos.isNotEmpty && widget.assetRecordStore != null)
                    ..._photoSection(l10n),
                ],
              ),
            ),
    );
  }

  /// Folded to one row until tapped; open, a few rows and See All.
  List<Widget> _photoSection(AppLocalizations l10n) {
    final preview = _photos.take(_photoPreview).toList();
    return [
      CupertinoListSection.insetGrouped(
        children: [
          CupertinoListTile(
            key: const ValueKey('placePhotos'),
            leading: const Icon(CupertinoIcons.photo_on_rectangle),
            title: Text(l10n.placePhotosHere),
            additionalInfo: Text('${_photos.length}'),
            trailing: Icon(
              _photosOpen
                  ? CupertinoIcons.chevron_up
                  : CupertinoIcons.chevron_down,
              size: 16,
              color: CupertinoColors.systemGrey,
            ),
            onTap: () => setState(() => _photosOpen = !_photosOpen),
          ),
        ],
      ),
      if (_photosOpen) ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.count(
            key: const ValueKey('placePhotoGrid'),
            crossAxisCount: 4,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final r in preview)
                GestureDetector(
                  onTap: _openPhotos,
                  child: assetImage(
                    r,
                    thumbnailSize: 200,
                    placeholder: () =>
                        const ColoredBox(color: CupertinoColors.systemGrey5),
                  ),
                ),
            ],
          ),
        ),
        if (_photos.length > preview.length)
          CupertinoButton(
            key: const ValueKey('placePhotosSeeAll'),
            onPressed: _openPhotos,
            child: Text(l10n.placePhotosSeeAll(_photos.length)),
          ),
      ],
    ];
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
