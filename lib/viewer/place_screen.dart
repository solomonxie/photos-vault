import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:intl/intl.dart';

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
import 'undo_toast.dart';

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

/// Of [records] (oldest first, as `listAll` keeps them), the ones taken on
/// [day] at [place], by the same rules as its page. A binary search to the
/// day, then that day's few only.
List<AssetRecord> photosAtOn(
  Place place,
  List<AssetRecord> records,
  DateTime day,
) {
  final start = DateTime(day.year, day.month, day.day);
  final end = start.add(const Duration(days: 1));
  var lo = 0;
  var hi = records.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (records[mid].createdAt.isBefore(start)) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final groups = <String, List<AssetRecord>>{};
  for (var i = lo; i < records.length; i++) {
    final r = records[i];
    if (!r.createdAt.isBefore(end)) break;
    if (r.passcodeHash != null || r.deletedAt != null) continue;
    (groups[r.location ?? ''] ??= []).add(r);
  }
  return switch (place.kind) {
    PlaceKind.point || PlaceKind.area => photosNear(place, groups),
    _ => photosNamedFor(place, groups),
  };
}

/// One stretch of days with photos at a place.
typedef Visit = ({DateTime from, DateTime to, List<AssetRecord> photos});

/// [photos] as visits, newest first: a gap of more than [gapDays] days
/// between two photos starts a new one.
List<Visit> visitsOf(List<AssetRecord> photos, {int gapDays = 2}) {
  final sorted = [...photos]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final out = <Visit>[];
  DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
  for (final r in sorted) {
    final day = dayOf(r.createdAt);
    if (out.isNotEmpty && day.difference(out.last.to).inDays <= gapDays) {
      final last = out.removeLast();
      out.add((from: last.from, to: day, photos: last.photos..add(r)));
    } else {
      out.add((from: day, to: day, photos: [r]));
    }
  }
  return out.reversed.toList();
}

/// "Apr 3 – 5, 2017", "Apr 3, 2017", "Apr 30 – May 2, 2017".
String visitLabel(Visit v) {
  final day = DateFormat.yMMMd();
  if (v.from == v.to) return day.format(v.from);
  if (v.from.year != v.to.year) {
    return '${day.format(v.from)} – ${day.format(v.to)}';
  }
  final md = DateFormat.MMMd();
  return '${md.format(v.from)} – ${md.format(v.to)}, ${v.to.year}';
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
  List<TravelRoute> _routes = const [];
  List<MapPinData> _pins = const [];

  /// Linked to its impressions, then taken there; newest first.
  List<AssetRecord> _photos = const [];
  bool _photosOpen = false;
  List<Visit> _visits = const [];
  bool _allVisits = false;

  /// A favourite if there is one, else the newest.
  AssetRecord? _cover;
  final _undo = UndoToast();

  static const _shownVisits = 4;

  @override
  void dispose() {
    _undo.dispose();
    super.dispose();
  }

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
      _visits = visitsOf(photos);
      _cover =
          photos.where((r) => r.isFavorite).firstOrNull ?? photos.firstOrNull;
      _place = place;
      _path = path;
      _inside = inside;
      _byId = byId;
      _tree = tree;
      _tally = PlaceTally.of(tree, counts);
      _entries = entries;
      _routes = routes;
      _photos = photos;
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
  Future<void> _move([Place? which]) async {
    final place = which ?? _place;
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

  Future<void> _openVisit(Visit v) async {
    final store = widget.assetRecordStore;
    final place = _place;
    if (store == null || place == null) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => AssetGroupScreen(
          title: '${place.name} · ${visitLabel(v)}',
          records: [...v.photos]
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
          assetRecordStore: store,
          travelStore: widget.travelStore,
        ),
      ),
    );
  }

  /// Gone at once, with five seconds to take it back.
  Future<bool> _deleteEntry(TravelEntry e) async {
    final l10n = AppLocalizations.of(context)!;
    final store = widget.travelStore;
    final links =
        (await store.linksFor(LinkOwner.entry, [e.id]))[e.id] ??
        const <TravelLink>[];
    await store.deleteEntry(e.id);
    unawaited(HapticFeedback.mediumImpact());
    if (!mounted) return true;
    _undo.show(context, l10n.footprintsDeleted, () async {
      await store.saveEntry(e);
      await store.setLinks(LinkOwner.entry, e.id, links);
      await _load();
    });
    await _load();
    return true;
  }

  /// A pin still in use stays, and says why.
  Future<bool> _deletePin(Place p) async {
    final l10n = AppLocalizations.of(context)!;
    final store = widget.travelStore;
    if (!await store.deletePlace(p.id)) {
      if (!mounted) return false;
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialog) => CupertinoAlertDialog(
          content: Text(l10n.placeDeleteInUse),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(dialog).pop(),
              child: Text(l10n.travelEntryDone),
            ),
          ],
        ),
      );
      return false;
    }
    unawaited(HapticFeedback.mediumImpact());
    if (!mounted) return true;
    _undo.show(context, l10n.footprintsDeleted, () async {
      await store.restorePlace(p);
      await _load();
    });
    await _load();
    return true;
  }

  /// Swipe left: delete; right, when given: [onStart] (e.g. Move).
  Widget _swipe({
    required Key key,
    required Widget child,
    required Future<bool> Function() onDelete,
    Future<void> Function()? onStart,
    String? startLabel,
  }) {
    final l10n = AppLocalizations.of(context)!;
    Widget back(Color color, String label, Alignment at) => ColoredBox(
      color: color,
      child: Align(
        alignment: at,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            label,
            style: const TextStyle(
              color: CupertinoColors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    return Dismissible(
      key: key,
      direction: onStart == null
          ? DismissDirection.endToStart
          : DismissDirection.horizontal,
      background: onStart == null
          ? back(
              CupertinoColors.destructiveRed,
              l10n.placeDelete,
              Alignment.centerRight,
            )
          : back(
              CupertinoColors.activeBlue,
              startLabel ?? '',
              Alignment.centerLeft,
            ),
      secondaryBackground: back(
        CupertinoColors.destructiveRed,
        l10n.placeDelete,
        Alignment.centerRight,
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await onStart?.call();
          return false;
        }
        return onDelete();
      },
      child: child,
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
                  if (_cover case final cover?)
                    GestureDetector(
                      key: const ValueKey('placeCover'),
                      onTap: _openPhotos,
                      child: SizedBox(
                        height: 220,
                        child: assetImage(
                          cover,
                          thumbnailSize: 900,
                          placeholder: () => const ColoredBox(
                            color: CupertinoColors.systemGrey5,
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        height: _cover == null ? 170 : 130,
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
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Expanded(
                              child: Text(
                                place.name,
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
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
                  if (_visits.isNotEmpty && widget.assetRecordStore != null)
                    CupertinoListSection.insetGrouped(
                      key: const ValueKey('placeVisits'),
                      header: Text(l10n.placeVisits(_visits.length)),
                      children: [
                        for (final v
                            in _allVisits
                                ? _visits
                                : _visits.take(_shownVisits))
                          CupertinoListTile(
                            key: ValueKey(
                              'placeVisit-${v.from.millisecondsSinceEpoch}',
                            ),
                            leading: const Icon(
                              CupertinoIcons.calendar,
                              color: CupertinoColors.systemPink,
                            ),
                            title: Text(visitLabel(v)),
                            additionalInfo: Text('${v.photos.length}'),
                            trailing: const CupertinoListTileChevron(),
                            onTap: () => _openVisit(v),
                          ),
                        if (_visits.length > _shownVisits)
                          CupertinoListTile(
                            key: const ValueKey('placeVisitsMore'),
                            title: Text(
                              _allVisits
                                  ? l10n.placesShowFewer
                                  : l10n.placesShowMore(
                                      _visits.length - _shownVisits,
                                    ),
                              style: const TextStyle(
                                color: CupertinoColors.activeBlue,
                              ),
                            ),
                            onTap: () =>
                                setState(() => _allVisits = !_allVisits),
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
                          _swipe(
                            key: ValueKey('placeSwipe-${p.id}'),
                            onDelete: () => _deletePin(p),
                            onStart: () => _move(p),
                            startLabel: l10n.placeMove,
                            child: placeTile(
                              l10n,
                              p,
                              _tally,
                              onTap: () => _openPlace(p.id),
                            ),
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
                        _swipe(
                          key: ValueKey('entrySwipe-${e.id}'),
                          onDelete: () => _deleteEntry(e),
                          child: impressionTile(
                            l10n,
                            e,
                            at: e.placeId == place.id
                                ? null
                                : _byId[e.placeId]?.name,
                            onTap: () => _read(e),
                          ),
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
/// and where inside the page's place it was written ([at]).
Widget impressionTile(
  AppLocalizations l10n,
  TravelEntry e, {
  String? at,
  required VoidCallback onTap,
}) {
  final text = e.text.trim().replaceAll(RegExp(r'\s*\n\s*'), ' ');
  final line = [
    if (at != null) l10n.impressionAt(at),
    if (travelEntryLine(e) case final l when l.isNotEmpty) l,
  ].join(' · ');
  return CupertinoListTile(
    key: ValueKey('placeEntry-${e.id}'),
    title: Text(
      text.isNotEmpty ? text : l10n.travelEntryUntitled,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: line.isEmpty
        ? null
        : Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: const CupertinoListTileChevron(),
    onTap: onTap,
  );
}
