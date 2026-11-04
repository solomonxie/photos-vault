import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record_store.dart';
import 'native_map.dart';
import 'route_screen.dart';
import '../photos/name_sound.dart';

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
    if (!mounted || detail == null) return;
    for (final c in [..._stopNotes, ..._legNotes]) {
      c.dispose();
    }
    setState(() {
      _detail = detail;
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
        title: Text(
          l10n.routeLegHowTo(
            _detail!.places[_detail!.stops[i + 1].placeId]?.name ?? '',
          ),
        ),
        actions: [
          for (final m in LegMode.values)
            if (m != LegMode.other)
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
          if (_detail!.legs[i].mode != LegMode.other)
            CupertinoActionSheetAction(
              key: const ValueKey('routeModeClear'),
              isDestructiveAction: true,
              onPressed: () => Navigator.of(sheet).pop(LegMode.other),
              child: Text(l10n.routeLegClear),
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
        backgroundColor: CupertinoColors.systemGroupedBackground,
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
            padding: const EdgeInsets.fromLTRB(36, 16, 20, 6),
            child: Text(
              l10n.routeStopsHeader.toUpperCase(),
              style: const TextStyle(
                fontSize: 13,
                color: CupertinoColors.systemGrey,
              ),
            ),
          ),
        ),
        SliverReorderableList(
          itemCount: detail.stops.length,
          onReorderItem: _reorder,
          itemBuilder: (context, i) => Dismissible(
            key: ValueKey('routeEditStop-$i-${detail.stops[i].placeId}'),
            direction: DismissDirection.endToStart,
            background: Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              color: CupertinoColors.destructiveRed,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: Text(
                l10n.actionDelete,
                style: const TextStyle(color: CupertinoColors.white),
              ),
            ),
            onDismissed: (_) => _removeStop(i),
            child: _EditableStop(
              key: ValueKey('routeStopRow-$i'),
              index: i,
              stop: detail.stops[i],
              place: detail.places[detail.stops[i].placeId],
              next: i + 1 < detail.stops.length
                  ? detail.places[detail.stops[i + 1].placeId]
                  : null,
              note: _stopNotes[i],
              onNoteChanged: () => _later('stop-$i', () => _writeStopNote(i)),
              onArrived: () => _pickArrived(i),
              leg: i < detail.legs.length ? detail.legs[i] : null,
              legNote: i < _legNotes.length ? _legNotes[i] : null,
              onLegNoteChanged: () => _later('leg-$i', () => _writeLegNote(i)),
              onMode: () => _pickMode(i),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: CupertinoColors.secondarySystemGroupedBackground
                  .resolveFrom(context),
              borderRadius: BorderRadius.vertical(
                top: detail.stops.isEmpty
                    ? const Radius.circular(10)
                    : Radius.zero,
                bottom: const Radius.circular(10),
              ),
            ),
            child: CupertinoListTile(
              key: const ValueKey('routeAddStop'),
              leading: const Icon(
                CupertinoIcons.add_circled_solid,
                color: CupertinoColors.activeBlue,
              ),
              title: Text(
                l10n.routeAddStop,
                style: const TextStyle(color: CupertinoColors.activeBlue),
              ),
              onTap: _addStop,
            ),
          ),
        ),
        if (detail.stops.length > 1)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(36, 6, 20, 0),
              child: Text(
                l10n.routeStopsHint,
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.systemGrey,
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: CupertinoListSection.insetGrouped(
            margin: const EdgeInsets.fromLTRB(20, 28, 20, 40),
            children: [
              CupertinoListTile(
                key: const ValueKey('routeDelete'),
                title: Center(
                  child: Text(
                    l10n.routeDelete,
                    style: const TextStyle(
                      color: CupertinoColors.destructiveRed,
                    ),
                  ),
                ),
                onTap: _delete,
              ),
            ],
          ),
        ),
      ],
    );
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

/// One stop in the card: number, name and day; a note; then how the trip
/// went on to the next one. Swipe to delete, drag the handle to move.
class _EditableStop extends StatelessWidget {
  const _EditableStop({
    super.key,
    required this.index,
    required this.stop,
    required this.place,
    required this.next,
    required this.note,
    required this.onNoteChanged,
    required this.onArrived,
    required this.leg,
    required this.legNote,
    required this.onLegNoteChanged,
    required this.onMode,
  });

  final int index;
  final RouteStop stop;
  final Place? place;
  final Place? next;
  final TextEditingController note;
  final VoidCallback onNoteChanged;
  final VoidCallback onArrived;
  final RouteLeg? leg;
  final TextEditingController? legNote;
  final VoidCallback onLegNoteChanged;
  final VoidCallback onMode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final leg = this.leg;
    const grey = CupertinoColors.systemGrey;
    final unset = leg == null || leg.mode == LegMode.other;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: index == 0
            ? const BorderRadius.vertical(top: Radius.circular(10))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 2),
            child: Row(
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
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    place?.name ?? '',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                CupertinoButton(
                  key: ValueKey('routeArrived-$index'),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(32, 32),
                  onPressed: onArrived,
                  child: Text(
                    stop.arrived == null
                        ? l10n.routeStopAddDate
                        : DateFormat.MMMd().format(stop.arrived!),
                    style: TextStyle(
                      fontSize: 15,
                      color: stop.arrived == null
                          ? CupertinoColors.activeBlue
                          : CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(4, 6, 10, 6),
                    child: Icon(
                      CupertinoIcons.line_horizontal_3,
                      size: 20,
                      color: grey,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(50, 0, 14, 4),
            child: CupertinoTextField.borderless(
              key: ValueKey('routeStopNote-$index'),
              controller: note,
              placeholder: l10n.routeStopNoteHint,
              padding: const EdgeInsets.symmetric(vertical: 4),
              style: const TextStyle(fontSize: 15),
              minLines: 1,
              maxLines: 6,
              onChanged: (_) => onNoteChanged(),
            ),
          ),
          if (leg != null && next != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 50),
              child: Align(
                alignment: Alignment.centerLeft,
                child: CupertinoButton(
                  key: ValueKey('routeLegMode-$index'),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  minimumSize: const Size(32, 28),
                  onPressed: onMode,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        unset
                            ? CupertinoIcons.arrow_down
                            : legModeIcon(leg.mode),
                        size: 15,
                        color: unset ? grey : CupertinoColors.activeBlue,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        unset
                            ? l10n.routeLegHowTo(next!.name)
                            : l10n.routeLegModeTo(
                                legModeLabel(l10n, leg.mode),
                                next!.name,
                              ),
                        style: TextStyle(
                          fontSize: 14,
                          color: unset ? grey : CupertinoColors.activeBlue,
                        ),
                      ),
                      const Icon(
                        CupertinoIcons.chevron_forward,
                        size: 12,
                        color: grey,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!unset || legNote!.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(50, 0, 14, 6),
                child: CupertinoTextField.borderless(
                  key: ValueKey('routeLegNote-$index'),
                  controller: legNote,
                  placeholder: l10n.routeLegNoteHint,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  style: const TextStyle(fontSize: 14),
                  minLines: 1,
                  maxLines: 4,
                  onChanged: (_) => onLegNoteChanged(),
                ),
              ),
          ],
          Container(
            height: 0.5,
            margin: const EdgeInsets.only(left: 50),
            color: CupertinoColors.separator.resolveFrom(context),
          ),
        ],
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
    final mine = searchByName(_mine, q, (p) => p.name);
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
