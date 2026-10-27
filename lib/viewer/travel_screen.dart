import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'native_map.dart';
import 'place_screen.dart';
import 'route_list_view.dart';

/// Places, grown into the travel diary (`docs/design/travel-diary.md`):
/// the places written about, on a map and by country; routes; and the
/// photo groups by place that Places always was.
class TravelScreen extends StatefulWidget {
  const TravelScreen({
    super.key,
    required this.travelStore,
    required this.placeSearch,
    this.assetRecordStore,
    this.personStore,
    this.placeGroups = const {},
    this.onOpenGroup,
  });

  final TravelStore travelStore;
  final PlaceSearch placeSearch;
  final AssetRecordStore? assetRecordStore;
  final PersonStore? personStore;

  /// Photos by place name, as the library already grouped them.
  final Map<String, List<AssetRecord>> placeGroups;
  final void Function(String title, List<AssetRecord> records)? onOpenGroup;

  @override
  State<TravelScreen> createState() => _TravelScreenState();
}

enum _Tab { places, routes, photos }

/// A country's cities, and the points no city claimed.
typedef _Country = ({String name, List<Place> cities, List<Place> loose});

class _TravelScreenState extends State<TravelScreen> {
  _Tab _tab = _Tab.places;
  bool _loaded = false;
  List<Place> _places = const [];
  List<MapPinData> _pins = const [];
  List<_Country> _countries = const [];
  Map<String, PlaceEntryCounts> _counts = const {};
  Map<String, int> _pointsIn = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final places = await widget.travelStore.places();
    final counts = await widget.travelStore.entryCountsByPlace();
    if (!mounted) return;
    final byId = {for (final p in places) p.id: p};
    final pointsIn = <String, int>{};
    final byCountry = <String, ({List<Place> cities, List<Place> loose})>{};
    ({List<Place> cities, List<Place> loose}) bucket(String country) =>
        byCountry.putIfAbsent(country, () => (cities: [], loose: []));
    for (final p in places) {
      if (p.isCity) {
        bucket(p.country).cities.add(p);
      } else if (byId[p.parentId] case final city?) {
        pointsIn[city.id] = (pointsIn[city.id] ?? 0) + 1;
      } else {
        bucket(p.country).loose.add(p);
      }
    }
    final countries =
        [
          for (final MapEntry(:key, :value) in byCountry.entries)
            (name: key, cities: value.cities, loose: value.loose),
        ]..sort((a, b) {
          // Unknown country last.
          if (a.name.isEmpty != b.name.isEmpty) return a.name.isEmpty ? 1 : -1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    setState(() {
      _loaded = true;
      _places = places;
      _counts = counts;
      _pointsIn = pointsIn;
      _countries = countries;
      _pins = [
        for (final p in places)
          MapPinData(id: p.id, lat: p.lat, lng: p.lng, title: p.name),
      ];
    });
  }

  Future<void> _open(String placeId) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PlaceScreen(
          travelStore: widget.travelStore,
          placeSearch: widget.placeSearch,
          placeId: placeId,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
          placeGroups: widget.placeGroups,
        ),
      ),
    );
    await _load();
  }

  Future<void> _add() async {
    final place = await showAddPlaceSheet(
      context: context,
      travelStore: widget.travelStore,
      placeSearch: widget.placeSearch,
    );
    if (place == null || !mounted) return;
    await _open(place.id);
  }

  Future<void> _dropPin(double lat, double lng) async {
    final place = await dropPlacePin(
      context: context,
      travelStore: widget.travelStore,
      placeSearch: widget.placeSearch,
      lat: lat,
      lng: lng,
    );
    if (place == null || !mounted) return;
    await _open(place.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.travelTitle),
        trailing: _tab == _Tab.places
            ? CupertinoButton(
                key: const ValueKey('travelAddPlace'),
                padding: EdgeInsets.zero,
                onPressed: _add,
                child: const Icon(CupertinoIcons.add),
              )
            : null,
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoSlidingSegmentedControl<_Tab>(
                  key: const ValueKey('travelTabs'),
                  groupValue: _tab,
                  children: {
                    _Tab.places: Text(l10n.travelSegmentPlaces),
                    _Tab.routes: Text(l10n.travelSegmentRoutes),
                    _Tab.photos: Text(l10n.travelSegmentPhotos),
                  },
                  onValueChanged: (t) => setState(() => _tab = t ?? _tab),
                ),
              ),
            ),
            Expanded(
              child: switch (_tab) {
                _Tab.places => _placesTab(l10n),
                _Tab.routes => RouteListView(
                  travelStore: widget.travelStore,
                  placeSearch: widget.placeSearch,
                  assetRecordStore: widget.assetRecordStore,
                  personStore: widget.personStore,
                ),
                _Tab.photos => _photosTab(l10n),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _placesTab(AppLocalizations l10n) {
    if (!_loaded) return const Center(child: CupertinoActivityIndicator());
    return Column(
      children: [
        SizedBox(
          height: 240,
          child: NativeMap(pins: _pins, onPinTap: _open, onLongPress: _dropPin),
        ),
        Expanded(
          child: _places.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.travelPlacesEmpty,
                      key: const ValueKey('travelPlacesEmpty'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: CupertinoColors.systemGrey),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    for (final c in _countries)
                      CupertinoListSection.insetGrouped(
                        header: Text(
                          c.name.isEmpty ? l10n.travelOtherPlaces : c.name,
                        ),
                        children: [
                          for (final p in [...c.cities, ...c.loose])
                            _placeTile(l10n, p),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _placeTile(AppLocalizations l10n, Place p) {
    final entries = _counts[p.id]?.total ?? 0;
    final points = _pointsIn[p.id] ?? 0;
    return CupertinoListTile(
      key: ValueKey('travelPlace-${p.id}'),
      leading: Icon(
        p.isCity ? CupertinoIcons.building_2_fill : CupertinoIcons.map_pin,
        color: CupertinoColors.systemTeal,
      ),
      title: Text(p.name),
      subtitle: points == 0 ? null : Text(l10n.travelPointsCount(points)),
      additionalInfo: entries == 0 ? null : Text('$entries'),
      trailing: const CupertinoListTileChevron(),
      onTap: () => _open(p.id),
    );
  }

  Widget _photosTab(AppLocalizations l10n) {
    final groups = widget.placeGroups.entries.toList();
    if (groups.isEmpty) {
      return Center(
        child: Text(
          l10n.collectionsPlacesEmpty,
          textAlign: TextAlign.center,
          style: const TextStyle(color: CupertinoColors.systemGrey),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        CupertinoListSection.insetGrouped(
          children: [
            for (final g in groups)
              CupertinoListTile(
                key: ValueKey('travelPhotos-${g.key}'),
                leading: const Icon(
                  CupertinoIcons.map_pin_ellipse,
                  color: CupertinoColors.systemTeal,
                ),
                title: Text(g.key),
                additionalInfo: Text('${g.value.length}'),
                trailing: const CupertinoListTileChevron(),
                onTap: () => widget.onOpenGroup?.call(g.key, g.value),
              ),
          ],
        ),
      ],
    );
  }
}

/// Finds a place by name with MapKit and saves it, or returns the one
/// already saved there. [near] biases the search (adding a point in a
/// city).
Future<Place?> showAddPlaceSheet({
  required BuildContext context,
  required TravelStore travelStore,
  required PlaceSearch placeSearch,
  Place? near,
}) => showCupertinoModalPopup<Place>(
  context: context,
  builder: (_) => _AddPlaceSheet(
    travelStore: travelStore,
    placeSearch: placeSearch,
    near: near,
  ),
);

/// A pin dropped on the map: asks its name, finds its city.
Future<Place?> dropPlacePin({
  required BuildContext context,
  required TravelStore travelStore,
  required PlaceSearch placeSearch,
  required double lat,
  required double lng,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final name = TextEditingController();
  final ok = await showCupertinoDialog<bool>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      title: Text(l10n.travelPinNameTitle),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: CupertinoTextField(
          key: const ValueKey('travelPinName'),
          controller: name,
          autofocus: true,
          placeholder: l10n.travelPinNamePlaceholder,
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(l10n.actionCancel),
        ),
        CupertinoDialogAction(
          key: const ValueKey('travelPinSave'),
          isDefaultAction: true,
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(l10n.travelEntrySave),
        ),
      ],
    ),
  );
  final typed = name.text.trim();
  name.dispose();
  if (ok != true || typed.isEmpty) return null;
  final city = await placeSearch.cityAt(lat, lng);
  final parent = city == null
      ? null
      : await travelStore.findOrCreateCity(
          name: city.$1,
          country: city.$2,
          lat: lat,
          lng: lng,
        );
  return travelStore.createPlace(
    name: typed,
    kind: PlaceKind.point,
    lat: lat,
    lng: lng,
    parentId: parent?.id,
    country: city?.$2 ?? '',
  );
}

/// [r] as a saved place: the one already there under that name, a city,
/// or a point filed under its city (made if needed).
Future<Place> savePlaceResult(
  TravelStore store,
  PlaceSearch search,
  PlaceResult r,
) async {
  // About 1 km for a point, 30 for a city: the same name that close is
  // the same place.
  final reach = r.isCity ? 0.3 : 0.01;
  for (final p in await store.places()) {
    if (p.isCity == r.isCity &&
        p.name.toLowerCase() == r.name.toLowerCase() &&
        (p.lat - r.lat).abs() < reach &&
        (p.lng - r.lng).abs() < reach) {
      return p;
    }
  }
  if (r.isCity) {
    return store.findOrCreateCity(
      name: r.name,
      country: r.country,
      lat: r.lat,
      lng: r.lng,
    );
  }
  final city = r.locality.isNotEmpty
      ? (r.locality, r.country)
      : await search.cityAt(r.lat, r.lng);
  final parent = city == null
      ? null
      : await store.findOrCreateCity(
          name: city.$1,
          country: city.$2,
          lat: r.lat,
          lng: r.lng,
        );
  return store.createPlace(
    name: r.name,
    kind: PlaceKind.point,
    lat: r.lat,
    lng: r.lng,
    parentId: parent?.id,
    country: r.country.isNotEmpty ? r.country : (city?.$2 ?? ''),
  );
}

class _AddPlaceSheet extends StatefulWidget {
  const _AddPlaceSheet({
    required this.travelStore,
    required this.placeSearch,
    this.near,
  });

  final TravelStore travelStore;
  final PlaceSearch placeSearch;
  final Place? near;

  @override
  State<_AddPlaceSheet> createState() => _AddPlaceSheetState();
}

class _AddPlaceSheetState extends State<_AddPlaceSheet> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<PlaceResult> _results = const [];
  bool _searching = false;
  bool _saving = false;

  /// Answers to an older query arriving late are dropped.
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(text));
  }

  Future<void> _search(String text) async {
    final query = text.trim();
    final generation = ++_generation;
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final near = widget.near;
    final results = await widget.placeSearch.search(
      query,
      near: near == null ? null : (near.lat, near.lng),
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  Future<void> _pick(PlaceResult r) async {
    setState(() => _saving = true);
    final place = await savePlaceResult(
      widget.travelStore,
      widget.placeSearch,
      r,
    );
    if (mounted) Navigator.of(context).pop(place);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final height = MediaQuery.sizeOf(context).height * 0.8;
    return CupertinoPopupSurface(
      child: SizedBox(
        height: height,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: CupertinoSearchTextField(
                        key: const ValueKey('travelPlaceSearch'),
                        controller: _query,
                        autofocus: true,
                        placeholder: l10n.travelSearchPlaceholder,
                        onChanged: _changed,
                        onSubmitted: _search,
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
              if (_searching || _saving)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: CupertinoActivityIndicator(),
                ),
              Expanded(
                child:
                    _results.isEmpty &&
                        !_searching &&
                        _query.text.trim().isNotEmpty
                    ? Center(
                        child: Text(
                          l10n.travelSearchNoResults,
                          style: const TextStyle(
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                      )
                    : ListView(
                        children: [
                          for (final (i, r) in _results.indexed)
                            CupertinoListTile(
                              key: ValueKey('travelSearchResult-$i'),
                              leading: Icon(
                                r.isCity
                                    ? CupertinoIcons.building_2_fill
                                    : CupertinoIcons.map_pin,
                                color: CupertinoColors.systemTeal,
                              ),
                              title: Text(r.name),
                              subtitle: Text(
                                [
                                  if (r.locality.isNotEmpty &&
                                      r.locality != r.name)
                                    r.locality,
                                  if (r.country.isNotEmpty) r.country,
                                ].join(', '),
                              ),
                              onTap: _saving ? null : () => _pick(r),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
