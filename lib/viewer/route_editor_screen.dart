import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart' show assetImage;
import 'asset_picker_screen.dart';
import 'native_map.dart';
import 'route_screen.dart';
import 'search_picker_sheet.dart';

/// Edits a route in place: every change is written as it's made, so there
/// is nothing to lose on the way back. Pops `true` when the route was
/// deleted.
class RouteEditorScreen extends StatefulWidget {
  const RouteEditorScreen({
    super.key,
    required this.travelStore,
    required this.placeSearch,
    required this.routeId,
    this.assetRecordStore,
    this.personStore,
    this.isNew = false,
  });

  final TravelStore travelStore;
  final PlaceSearch placeSearch;
  final String routeId;
  final AssetRecordStore? assetRecordStore;
  final PersonStore? personStore;

  /// Just created: left with nothing in it, it's deleted again.
  final bool isNew;

  @override
  State<RouteEditorScreen> createState() => _RouteEditorScreenState();
}

class _RouteEditorScreenState extends State<RouteEditorScreen> {
  TravelStore get _store => widget.travelStore;

  RouteDetail? _detail;
  final _title = TextEditingController();
  final _note = TextEditingController();
  List<TextEditingController> _stopNotes = const [];
  List<TextEditingController> _legNotes = const [];
  final _pending = <String, Timer>{};
  final _writes = <Future<void>>[];
  List<TravelLink> _links = const [];
  Map<String, Person> _people = const {};
  bool _deleted = false;

  @override
  void initState() {
    super.initState();
    _load(fields: true);
  }

  @override
  void dispose() {
    for (final t in _pending.values) {
      t.cancel();
    }
    for (final c in [_title, _note, ..._stopNotes, ..._legNotes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool fields = false}) async {
    await Future.wait(_writes);
    final detail = await _store.routeDetail(widget.routeId);
    final links =
        (await _store.linksFor(LinkOwner.route, [
          widget.routeId,
        ]))[widget.routeId] ??
        const <TravelLink>[];
    var people = _people;
    if (people.isEmpty &&
        links.any((l) => l.target == LinkTarget.person) &&
        widget.personStore != null) {
      people = {for (final p in await widget.personStore!.listAll()) p.id: p};
    }
    if (!mounted || detail == null) return;
    for (final c in [..._stopNotes, ..._legNotes]) {
      c.dispose();
    }
    setState(() {
      _detail = detail;
      _links = links;
      _people = people;
      if (fields) {
        _title.text = detail.route.title;
        _note.text = detail.route.note;
      }
      _stopNotes = [
        for (final s in detail.stops) TextEditingController(text: s.note),
      ];
      _legNotes = [
        for (final l in detail.legs) TextEditingController(text: l.note),
      ];
    });
  }

  void _track(Future<void> write) {
    _writes.add(write);
    write.whenComplete(() => _writes.remove(write));
  }

  TravelRoute? get _route => _detail?.route;

  void _saveRoute() {
    final route = _route;
    if (route == null || _deleted) return;
    if (route.title == _title.text.trim() && route.note == _note.text.trim()) {
      return;
    }
    final next = route.copyWith(
      title: _title.text.trim(),
      note: _note.text.trim(),
    );
    _detail = RouteDetail(
      route: next,
      stops: _detail!.stops,
      legs: _detail!.legs,
      places: _detail!.places,
    );
    _track(_store.updateRoute(next));
  }

  /// Every way out comes here: the page behind reloads once this pops, so
  /// everything is written first.
  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    _flush();
    _saveRoute();
    await Future.wait(_writes);
    if (widget.isNew) await _dropIfEmpty();
    if (mounted) Navigator.of(context).pop(false);
  }

  bool _finishing = false;

  Future<void> _dropIfEmpty() async {
    final detail = await _store.routeDetail(widget.routeId);
    if (detail != null &&
        detail.route.title.isEmpty &&
        detail.route.note.isEmpty &&
        detail.stops.isEmpty) {
      await _store.deleteRoute(widget.routeId);
    }
  }

  /// A note typed is written once typing pauses.
  void _later(String key, Future<void> Function() write) {
    _pending.remove(key)?.cancel();
    _pending[key] = Timer(const Duration(milliseconds: 500), () {
      _pending.remove(key);
      _track(write());
    });
  }

  void _flush() {
    for (final key in _pending.keys.toList()) {
      _pending.remove(key)!.cancel();
      final i = int.parse(key.substring(key.indexOf('-') + 1));
      if (key.startsWith('stop-')) {
        _track(_writeStopNote(i));
      } else {
        _track(_writeLegNote(i));
      }
    }
  }

  Future<void> _writeStopNote(int i) {
    final stop = _detail!.stops[i].copyWith(note: _stopNotes[i].text.trim());
    _detail!.stops[i] = stop;
    return _store.saveStop(widget.routeId, i, stop);
  }

  Future<void> _writeLegNote(int i) {
    final leg = _detail!.legs[i].copyWith(note: _legNotes[i].text.trim());
    _detail!.legs[i] = leg;
    return _store.saveLeg(widget.routeId, i, leg);
  }

  Future<void> _setStops(List<RouteStop> stops) async {
    _flush();
    await Future.wait(_writes);
    await _store.setStops(widget.routeId, stops);
    await _load();
  }

  Future<void> _addPlace(Place place) =>
      _setStops([..._detail!.stops, RouteStop(placeId: place.id)]);

  Future<void> _addStop() async {
    final stops = _detail!.stops;
    final last = stops.isEmpty ? null : _detail!.places[stops.last.placeId];
    final picked = await showCupertinoModalPopup<Object>(
      context: context,
      builder: (_) => _PlaceSearchSheet(
        travelStore: _store,
        placeSearch: widget.placeSearch,
        near: last == null ? null : (last.lat, last.lng),
      ),
    );
    if (picked == null || !mounted) return;
    final place = picked is Place
        ? picked
        : await placeFromResult(_store, picked as PlaceResult);
    await _addPlace(place);
  }

  Future<void> _dropPin(double lat, double lng) async {
    final name = AppLocalizations.of(context)!.routeDroppedPin;
    final city = await widget.placeSearch.cityAt(lat, lng);
    final parent = city == null
        ? null
        : await _store.findOrCreateCity(
            name: city.$1,
            country: city.$2,
            lat: lat,
            lng: lng,
          );
    final place = await _store.createPlace(
      name: name,
      kind: PlaceKind.point,
      lat: lat,
      lng: lng,
      parentId: parent?.id,
      country: city?.$2 ?? '',
    );
    await _addPlace(place);
  }

  Future<void> _removeStop(int i) =>
      _setStops([..._detail!.stops]..removeAt(i));

  Future<void> _reorder(int from, int to) {
    final stops = [..._detail!.stops];
    final moved = stops.removeAt(from);
    stops.insert(to, moved);
    return _setStops(stops);
  }

  Future<void> _pickMode(int i) async {
    final l10n = AppLocalizations.of(context)!;
    final mode = await showCupertinoModalPopup<LegMode>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        actions: [
          for (final m in LegMode.values)
            CupertinoActionSheetAction(
              key: ValueKey('routeMode-${m.name}'),
              onPressed: () => Navigator.of(sheet).pop(m),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(legModeIcon(m), size: 20),
                  const SizedBox(width: 8),
                  Text(legModeLabel(l10n, m)),
                ],
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (mode == null || !mounted) return;
    final leg = _detail!.legs[i].copyWith(
      mode: mode,
      note: _legNotes[i].text.trim(),
      needsReview: false,
    );
    setState(() => _detail!.legs[i] = leg);
    _track(_store.saveLeg(widget.routeId, i, leg));
  }

  void _clearReview(int i) {
    final leg = _detail!.legs[i].copyWith(needsReview: false);
    setState(() => _detail!.legs[i] = leg);
    _track(_store.saveLeg(widget.routeId, i, leg));
  }

  Future<void> _pickArrived(int i) async {
    final stop = _detail!.stops[i];
    final picked = await _pickDate(context, stop.arrived);
    if (picked == null || !mounted) return;
    final next = stop.copyWith(arrived: () => picked.value);
    setState(() => _detail!.stops[i] = next);
    _track(_store.saveStop(widget.routeId, i, next));
  }

  Future<void> _pickRouteDate({required bool start}) async {
    final route = _route!;
    final picked = await _pickDate(context, start ? route.starts : route.ends);
    if (picked == null || !mounted) return;
    final next = start
        ? route.copyWith(starts: () => picked.value)
        : route.copyWith(ends: () => picked.value);
    setState(
      () => _detail = RouteDetail(
        route: next,
        stops: _detail!.stops,
        legs: _detail!.legs,
        places: _detail!.places,
      ),
    );
    _track(_store.updateRoute(next));
  }

  Future<void> _saveLinks(List<TravelLink> links) async {
    setState(() => _links = links);
    _track(_store.setLinks(LinkOwner.route, widget.routeId, links));
  }

  Future<void> _addPhotos() async {
    final store = widget.assetRecordStore;
    if (store == null) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await Navigator.of(context).push<List<AssetRecord>>(
      CupertinoPageRoute(
        builder: (_) => AssetPickerScreen(
          title: l10n.routeAddPhotos,
          assetRecordStore: store,
          excludeIds: {
            for (final l in _links)
              if (l.target == LinkTarget.asset) l.id,
          },
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    await _saveLinks([
      ..._links,
      for (final r in picked) TravelLink(LinkTarget.asset, r.localId),
    ]);
  }

  Future<void> _choosePeople() async {
    final store = widget.personStore;
    if (store == null) return;
    final l10n = AppLocalizations.of(context)!;
    final all = await store.listAll();
    if (!mounted) return;
    _people = {for (final p in all) p.id: p};
    final linked = {
      for (final l in _links)
        if (l.target == LinkTarget.person) l.id,
    };
    final picked = await showSearchPickerSheetMulti<Person>(
      context: context,
      title: l10n.routeChoosePeople,
      options: [
        for (final p in all)
          if (!linked.contains(p.id)) p,
      ],
      labelOf: (p) => p.name,
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    await _saveLinks([
      ..._links,
      for (final p in picked) TravelLink(LinkTarget.person, p.id),
    ]);
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        content: Text(l10n.routeDeleteConfirm),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('routeDeleteConfirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
    _deleted = true;
    await Future.wait(_writes);
    await _store.deleteRoute(widget.routeId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final detail = _detail;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish();
      },
      child: CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          automaticallyImplyLeading: false,
          middle: Text(l10n.routeEditorTitle),
          trailing: CupertinoButton(
            key: const ValueKey('routeEditorDone'),
            padding: EdgeInsets.zero,
            onPressed: _finish,
            child: Text(l10n.actionDone),
          ),
        ),
        child: SafeArea(
          child: detail == null
              ? const Center(child: CupertinoActivityIndicator())
              : _body(l10n, detail),
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n, RouteDetail detail) {
    final stops = [for (final s in detail.stops) detail.places[s.placeId]]
        .whereType<Place>()
        .toList();
    final (pins, line) = routeMapData(stops, {
      for (final (i, l) in detail.legs.indexed)
        if (l.mode == LegMode.flight) i,
    });
    final route = detail.route;
    final date = DateFormat.yMMMd();
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 220,
            child: NativeMap(pins: pins, line: line, onLongPress: _dropPin),
          ),
        ),
        SliverToBoxAdapter(
          child: CupertinoListSection.insetGrouped(
            children: [
              CupertinoTextField.borderless(
                key: const ValueKey('routeTitleField'),
                controller: _title,
                placeholder: l10n.routeTitleHint,
                padding: const EdgeInsets.all(14),
                style: const TextStyle(fontSize: 17),
                onEditingComplete: _saveRoute,
                onTapOutside: (_) => _saveRoute(),
              ),
              CupertinoTextField.borderless(
                key: const ValueKey('routeNoteField'),
                controller: _note,
                placeholder: l10n.routeNoteHint,
                padding: const EdgeInsets.all(14),
                minLines: 2,
                maxLines: 8,
                onTapOutside: (_) => _saveRoute(),
              ),
              CupertinoListTile(
                key: const ValueKey('routeStarts'),
                title: Text(l10n.routeStarts),
                additionalInfo: Text(
                  route.starts == null
                      ? l10n.routeNoDate
                      : date.format(route.starts!),
                ),
                onTap: () => _pickRouteDate(start: true),
              ),
              CupertinoListTile(
                key: const ValueKey('routeEnds'),
                title: Text(l10n.routeEnds),
                additionalInfo: Text(
                  route.ends == null
                      ? l10n.routeNoDate
                      : date.format(route.ends!),
                ),
                onTap: () => _pickRouteDate(start: false),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.routeStopsHeader,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                CupertinoButton(
                  key: const ValueKey('routeAddStop'),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onPressed: _addStop,
                  child: Text(l10n.routeAddStop),
                ),
              ],
            ),
          ),
        ),
        if (detail.stops.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                l10n.routeNoStops,
                style: const TextStyle(color: CupertinoColors.systemGrey),
              ),
            ),
          ),
        SliverReorderableList(
          itemCount: detail.stops.length,
          onReorderItem: _reorder,
          itemBuilder: (context, i) => _EditableStop(
            key: ValueKey('routeEditStop-$i-${detail.stops[i].placeId}'),
            index: i,
            stop: detail.stops[i],
            place: detail.places[detail.stops[i].placeId],
            note: _stopNotes[i],
            onNoteChanged: () => _later('stop-$i', () => _writeStopNote(i)),
            onArrived: () => _pickArrived(i),
            onRemove: () => _removeStop(i),
            leg: i < detail.legs.length ? detail.legs[i] : null,
            legNote: i < _legNotes.length ? _legNotes[i] : null,
            onLegNoteChanged: () => _later('leg-$i', () => _writeLegNote(i)),
            onMode: () => _pickMode(i),
            onReviewed: () => _clearReview(i),
          ),
        ),
        ..._photosSection(l10n),
        ..._peopleSection(l10n),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 32, 16, 40),
            child: CupertinoButton(
              key: const ValueKey('routeDelete'),
              onPressed: _delete,
              child: Text(
                l10n.routeDelete,
                style: const TextStyle(color: CupertinoColors.destructiveRed),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(
    String title,
    String action,
    Key key,
    VoidCallback on,
  ) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          CupertinoButton(
            key: key,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            onPressed: on,
            child: Text(action),
          ),
        ],
      ),
    ),
  );

  List<Widget> _photosSection(AppLocalizations l10n) {
    final store = widget.assetRecordStore;
    if (store == null) return const [];
    final records = store.visibleById;
    final shown = [
      for (final l in _links)
        if (l.target == LinkTarget.asset) ?records[l.id],
    ];
    return [
      _sectionHeader(
        l10n.routePhotos,
        l10n.routeAddPhotos,
        const ValueKey('routeAddPhotos'),
        _addPhotos,
      ),
      if (shown.isNotEmpty)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: shown.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (context, i) => Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox.square(
                      dimension: 84,
                      child: assetImage(
                        shown[i],
                        thumbnailSize: 200,
                        placeholder: () => const ColoredBox(
                          color: CupertinoColors.systemGrey5,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: () => _saveLinks([
                        for (final l in _links)
                          if (l !=
                              TravelLink(LinkTarget.asset, shown[i].localId))
                            l,
                      ]),
                      child: const Icon(
                        CupertinoIcons.xmark_circle_fill,
                        size: 20,
                        color: CupertinoColors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  List<Widget> _peopleSection(AppLocalizations l10n) {
    if (widget.personStore == null) return const [];
    final people = [
      for (final l in _links)
        if (l.target == LinkTarget.person && _people[l.id] != null)
          _people[l.id]!,
    ];
    return [
      _sectionHeader(
        l10n.routePeople,
        l10n.routeChoosePeople,
        const ValueKey('routeChoosePeople'),
        _choosePeople,
      ),
      if (people.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in people)
                  RouteChip(
                    p.name,
                    onDelete: () => _saveLinks([
                      for (final l in _links)
                        if (l != TravelLink(LinkTarget.person, p.id)) l,
                    ]),
                  ),
              ],
            ),
          ),
        ),
    ];
  }
}

/// A place for a search result: an existing one at (about) the same spot
/// first, else a new city, or a new point inside its city.
Future<Place> placeFromResult(TravelStore store, PlaceResult r) async {
  if (r.isCity) {
    return store.findOrCreateCity(
      name: r.name,
      country: r.country,
      lat: r.lat,
      lng: r.lng,
    );
  }
  for (final p in await store.places()) {
    if (!p.isCity &&
        p.name.toLowerCase() == r.name.toLowerCase() &&
        (p.lat - r.lat).abs() < 0.002 &&
        (p.lng - r.lng).abs() < 0.002) {
      return p;
    }
  }
  final city = r.locality.isEmpty
      ? null
      : await store.findOrCreateCity(
          name: r.locality,
          country: r.country,
          lat: r.lat,
          lng: r.lng,
        );
  return store.createPlace(
    name: r.name,
    kind: PlaceKind.point,
    lat: r.lat,
    lng: r.lng,
    parentId: city?.id,
    country: r.country,
  );
}

/// A date, or "no date": null when dismissed, a record (even holding null)
/// when chosen.
Future<({DateTime? value})?> _pickDate(
  BuildContext context,
  DateTime? initial,
) {
  final l10n = AppLocalizations.of(context)!;
  var chosen = initial ?? DateTime.now();
  return showCupertinoModalPopup<({DateTime? value})>(
    context: context,
    builder: (sheet) => Container(
      height: 300,
      color: CupertinoColors.systemBackground.resolveFrom(sheet),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Row(
              children: [
                CupertinoButton(
                  onPressed: () => Navigator.of(sheet).pop((value: null)),
                  child: Text(l10n.actionClear),
                ),
                const Spacer(),
                CupertinoButton(
                  key: const ValueKey('routeDateDone'),
                  onPressed: () => Navigator.of(sheet).pop((value: chosen)),
                  child: Text(l10n.actionDone),
                ),
              ],
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: chosen,
                onDateTimeChanged: (d) =>
                    chosen = DateTime(d.year, d.month, d.day),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EditableStop extends StatelessWidget {
  const _EditableStop({
    super.key,
    required this.index,
    required this.stop,
    required this.place,
    required this.note,
    required this.onNoteChanged,
    required this.onArrived,
    required this.onRemove,
    required this.leg,
    required this.legNote,
    required this.onLegNoteChanged,
    required this.onMode,
    required this.onReviewed,
  });

  final int index;
  final RouteStop stop;
  final Place? place;
  final TextEditingController note;
  final VoidCallback onNoteChanged;
  final VoidCallback onArrived;
  final VoidCallback onRemove;
  final RouteLeg? leg;
  final TextEditingController? legNote;
  final VoidCallback onLegNoteChanged;
  final VoidCallback onMode;
  final VoidCallback onReviewed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final leg = this.leg;
    final grey = CupertinoColors.systemGrey;
    return ColoredBox(
      color: CupertinoColors.systemBackground.resolveFrom(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: CupertinoColors.activeBlue,
                  ),
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    place?.name ?? '',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                CupertinoButton(
                  key: ValueKey('routeArrived-$index'),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(32, 32),
                  onPressed: onArrived,
                  child: Text(
                    stop.arrived == null
                        ? l10n.routeStopArrived
                        : DateFormat.yMMMd().format(stop.arrived!),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                CupertinoButton(
                  key: ValueKey('routeRemoveStop-$index'),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(32, 32),
                  onPressed: onRemove,
                  child: const Icon(
                    CupertinoIcons.minus_circle_fill,
                    size: 20,
                    color: CupertinoColors.destructiveRed,
                  ),
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      CupertinoIcons.line_horizontal_3,
                      size: 20,
                      color: grey,
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 34, right: 8),
              child: CupertinoTextField(
                key: ValueKey('routeStopNote-$index'),
                controller: note,
                placeholder: l10n.routeStopNoteHint,
                minLines: 1,
                maxLines: 6,
                onChanged: (_) => onNoteChanged(),
              ),
            ),
            if (leg != null && legNote != null)
              Padding(
                padding: const EdgeInsets.only(left: 34, right: 8, top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CupertinoButton(
                          key: ValueKey('routeLegMode-$index'),
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(32, 28),
                          onPressed: onMode,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(legModeIcon(leg.mode), size: 16),
                              const SizedBox(width: 6),
                              Text(
                                legModeLabel(l10n, leg.mode),
                                style: const TextStyle(fontSize: 14),
                              ),
                              const Icon(CupertinoIcons.chevron_down, size: 12),
                            ],
                          ),
                        ),
                        if (leg.needsReview) ...[
                          const Spacer(),
                          CupertinoButton(
                            key: ValueKey('routeLegReviewed-$index'),
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(28, 28),
                            onPressed: onReviewed,
                            child: const Icon(
                              CupertinoIcons.exclamationmark_triangle_fill,
                              size: 16,
                              color: CupertinoColors.systemOrange,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (leg.needsReview)
                      Text(
                        l10n.routeLegReview,
                        style: const TextStyle(
                          fontSize: 12,
                          color: CupertinoColors.systemOrange,
                        ),
                      ),
                    const SizedBox(height: 4),
                    CupertinoTextField(
                      key: ValueKey('routeLegNote-$index'),
                      controller: legNote,
                      placeholder: l10n.routeLegNoteHint,
                      minLines: 1,
                      maxLines: 6,
                      onChanged: (_) => onLegNoteChanged(),
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

/// Your places matching what's typed, then MapKit's. Pops a [Place] or a
/// [PlaceResult].
class _PlaceSearchSheet extends StatefulWidget {
  const _PlaceSearchSheet({
    required this.travelStore,
    required this.placeSearch,
    this.near,
  });

  final TravelStore travelStore;
  final PlaceSearch placeSearch;
  final (double, double)? near;

  @override
  State<_PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<_PlaceSearchSheet> {
  final _query = TextEditingController();
  List<Place> _mine = const [];
  List<PlaceResult> _found = const [];
  Timer? _debounce;
  int _generation = 0;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    widget.travelStore.places().then((all) {
      if (mounted) setState(() => _mine = all);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    final generation = ++_generation;
    setState(() => _searching = true);
    final found = await widget.placeSearch.search(q, near: widget.near);
    if (!mounted || generation != _generation) return;
    setState(() {
      _found = found;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final q = _query.text.trim().toLowerCase();
    final mine = [
      for (final p in _mine)
        if (q.isEmpty || p.name.toLowerCase().contains(q)) p,
    ];
    final height = MediaQuery.sizeOf(context).height * 0.8;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: CupertinoSearchTextField(
                      key: const ValueKey('routePlaceSearch'),
                      controller: _query,
                      autofocus: true,
                      placeholder: l10n.routeSearchHint,
                      onChanged: _changed,
                    ),
                  ),
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.actionCancel),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (mine.isNotEmpty) ...[
                    _label(l10n.routeAddStopExisting),
                    for (final p in mine.take(30))
                      CupertinoListTile(
                        key: ValueKey('routeMinePlace-${p.id}'),
                        leading: Icon(
                          p.isCity
                              ? CupertinoIcons.building_2_fill
                              : CupertinoIcons.map_pin,
                        ),
                        title: Text(p.name),
                        subtitle: p.country.isEmpty ? null : Text(p.country),
                        onTap: () => Navigator.of(context).pop(p),
                      ),
                  ],
                  if (q.isNotEmpty) ...[
                    _label(l10n.routeAddStopSearch),
                    if (_searching && _found.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: CupertinoActivityIndicator(),
                      )
                    else if (_found.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          l10n.routeSearchNone,
                          style: const TextStyle(
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                      ),
                    for (final (i, r) in _found.indexed)
                      CupertinoListTile(
                        key: ValueKey('routeFoundPlace-$i'),
                        leading: Icon(
                          r.isCity
                              ? CupertinoIcons.building_2_fill
                              : CupertinoIcons.map_pin_ellipse,
                        ),
                        title: Text(r.name),
                        subtitle: Text(
                          [
                            if (r.locality.isNotEmpty && r.locality != r.name)
                              r.locality,
                            if (r.country.isNotEmpty) r.country,
                          ].join(', '),
                        ),
                        onTap: () => Navigator.of(context).pop(r),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(fontSize: 12, color: CupertinoColors.systemGrey),
    ),
  );
}
