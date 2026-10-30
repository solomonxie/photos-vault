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

/// Footprints → Places (`docs/design/travel-diary.md`): every place on a
/// map, and the top of the tree (countries) below it. The library's photo
/// groups by location are one row away.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({
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
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  bool _loaded = false;
  List<Place> _top = const [];
  List<MapPinData> _pins = const [];
  PlaceTally _tally = const PlaceTally({}, {});

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final places = await widget.travelStore.places();
    final counts = await widget.travelStore.entryCountsByPlace();
    if (!mounted) return;
    final tree = placeTree(places);
    setState(() {
      _loaded = true;
      _top = tree[null] ?? const [];
      _tally = PlaceTally.of(tree, counts);
      _pins = [
        for (final p in places)
          if (!p.isCountry)
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

  void _openPhotoPlaces() => Navigator.of(context).push(
    CupertinoPageRoute(
      builder: (_) => PhotoPlacesScreen(
        groups: widget.placeGroups,
        onOpenGroup: widget.onOpenGroup,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.footprintsPlaces),
        trailing: CupertinoButton(
          key: const ValueKey('travelAddPlace'),
          padding: EdgeInsets.zero,
          onPressed: _add,
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: !_loaded
            ? const Center(child: CupertinoActivityIndicator())
            : Column(
                children: [
                  SizedBox(
                    height: 240,
                    child: NativeMap(
                      pins: _pins,
                      onPinTap: _open,
                      onLongPress: _dropPin,
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 32),
                      children: [
                        if (widget.placeGroups.isNotEmpty)
                          CupertinoListSection.insetGrouped(
                            children: [
                              CupertinoListTile(
                                key: const ValueKey('placesPhotoGroups'),
                                leading: const Icon(
                                  CupertinoIcons.map_pin_ellipse,
                                  color: CupertinoColors.systemTeal,
                                ),
                                title: Text(l10n.placesPhotosByLocation),
                                additionalInfo: Text(
                                  '${widget.placeGroups.length}',
                                ),
                                trailing: const CupertinoListTileChevron(),
                                onTap: _openPhotoPlaces,
                              ),
                            ],
                          ),
                        if (_top.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              l10n.travelPlacesEmpty,
                              key: const ValueKey('travelPlacesEmpty'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: CupertinoColors.systemGrey,
                              ),
                            ),
                          )
                        else
                          CupertinoListSection.insetGrouped(
                            children: [
                              for (final p in _top)
                                placeTile(
                                  l10n,
                                  p,
                                  _tally,
                                  onTap: () => _open(p.id),
                                ),
                            ],
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

/// What's under each place, rolled up: its own places and every
/// impression at it or anywhere below it.
class PlaceTally {
  const PlaceTally(this.children, this.impressions);

  /// Direct children, by place id.
  final Map<String, int> children;

  /// Entries at the place or below it.
  final Map<String, int> impressions;

  static PlaceTally of(
    Map<String?, List<Place>> tree,
    Map<String, PlaceEntryCounts> counts,
  ) {
    final impressions = <String, int>{};
    final visiting = <String>{};
    int below(String id) {
      if (impressions[id] case final n?) return n;
      // A parent loop counts each place once, not forever.
      if (!visiting.add(id)) return 0;
      var n = counts[id]?.total ?? 0;
      for (final c in tree[id] ?? const <Place>[]) {
        n += below(c.id);
      }
      return impressions[id] = n;
    }

    for (final list in tree.values) {
      for (final p in list) {
        below(p.id);
      }
    }
    return PlaceTally({
      for (final MapEntry(:key, :value) in tree.entries) ?key: value.length,
    }, impressions);
  }
}

IconData placeIcon(PlaceKind kind) => switch (kind) {
  PlaceKind.country => CupertinoIcons.flag_fill,
  PlaceKind.city => CupertinoIcons.building_2_fill,
  PlaceKind.area => CupertinoIcons.square_grid_2x2_fill,
  PlaceKind.point => CupertinoIcons.map_pin,
};

String placeKindLabel(AppLocalizations l10n, PlaceKind kind) => switch (kind) {
  PlaceKind.country => l10n.placeKindCountry,
  PlaceKind.city => l10n.placeKindCity,
  PlaceKind.area => l10n.placeKindArea,
  PlaceKind.point => l10n.placeKindPin,
};

/// A place in a list: what kind it is, what's in it, how many impressions.
Widget placeTile(
  AppLocalizations l10n,
  Place p,
  PlaceTally tally, {
  required VoidCallback onTap,
}) {
  final inside = tally.children[p.id] ?? 0;
  final notes = tally.impressions[p.id] ?? 0;
  final sub = [
    if (p.category.isNotEmpty) p.category,
    if (p.address.isNotEmpty) p.address,
    if (inside > 0) l10n.placeInsideCount(inside),
  ].join(' · ');
  return CupertinoListTile(
    key: ValueKey('travelPlace-${p.id}'),
    leading: Icon(placeIcon(p.kind), color: CupertinoColors.systemTeal),
    title: Text(p.name),
    subtitle: sub.isEmpty ? null : Text(sub),
    additionalInfo: notes == 0 ? null : Text('$notes'),
    trailing: const CupertinoListTileChevron(),
    onTap: onTap,
  );
}

/// The library's photos grouped by the location name they were filed
/// under: what Places was before the travel diary.
class PhotoPlacesScreen extends StatelessWidget {
  const PhotoPlacesScreen({super.key, required this.groups, this.onOpenGroup});

  final Map<String, List<AssetRecord>> groups;
  final void Function(String title, List<AssetRecord> records)? onOpenGroup;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.placesPhotosByLocation),
      ),
      child: SafeArea(
        child: groups.isEmpty
            ? Center(
                child: Text(
                  l10n.collectionsPlacesEmpty,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  CupertinoListSection.insetGrouped(
                    children: [
                      for (final g in groups.entries)
                        CupertinoListTile(
                          key: ValueKey('travelPhotos-${g.key}'),
                          leading: const Icon(
                            CupertinoIcons.map_pin_ellipse,
                            color: CupertinoColors.systemTeal,
                          ),
                          title: Text(g.key),
                          additionalInfo: Text('${g.value.length}'),
                          trailing: const CupertinoListTileChevron(),
                          onTap: () => onOpenGroup?.call(g.key, g.value),
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// Finds a place by name with MapKit and saves it, or returns the one
/// already saved there. Given [under], the new place goes inside it;
/// otherwise it's filed under its country and city.
Future<Place?> showAddPlaceSheet({
  required BuildContext context,
  required TravelStore travelStore,
  required PlaceSearch placeSearch,
  Place? near,
  Place? under,
}) => showCupertinoModalPopup<Place>(
  context: context,
  builder: (_) => _AddPlaceSheet(
    travelStore: travelStore,
    placeSearch: placeSearch,
    near: near ?? under,
    under: under,
  ),
);

/// A pin dropped on the map: asks its name; inside [under], or filed
/// under the country and city it's in.
Future<Place?> dropPlacePin({
  required BuildContext context,
  required TravelStore travelStore,
  required PlaceSearch placeSearch,
  required double lat,
  required double lng,
  Place? under,
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
  if (under != null) {
    return travelStore.createPlace(
      name: typed,
      kind: PlaceKind.point,
      lat: lat,
      lng: lng,
      parentId: under.id,
      country: under.country,
    );
  }
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

/// [r] as a saved place: the one already there under that name, or a new
/// one — inside [under] when given, else under its country and city (made
/// if needed).
Future<Place> savePlaceResult(
  TravelStore store,
  PlaceSearch search,
  PlaceResult r, {
  Place? under,
}) async {
  // About 1 km for a pin, 30 for anything bigger: the same name that close
  // is the same place.
  final reach = r.kind == PlaceKind.point ? 0.01 : 0.3;
  for (final p in await store.places()) {
    if (p.kind == r.kind &&
        p.name.toLowerCase() == r.name.toLowerCase() &&
        (p.lat - r.lat).abs() < reach &&
        (p.lng - r.lng).abs() < reach) {
      return p;
    }
  }
  Future<Place> make(String? parentId, String country) => store.createPlace(
    name: r.name,
    kind: r.kind,
    lat: r.lat,
    lng: r.lng,
    parentId: parentId,
    country: country,
    address: r.address,
    category: r.category,
  );
  if (under != null) {
    return make(under.id, r.country.isNotEmpty ? r.country : under.country);
  }
  switch (r.kind) {
    case PlaceKind.country:
      return (await store.findOrCreateCountry(r.name, lat: r.lat, lng: r.lng))!;
    case PlaceKind.city:
      return store.findOrCreateCity(
        name: r.name,
        country: r.country,
        lat: r.lat,
        lng: r.lng,
      );
    case PlaceKind.area || PlaceKind.point:
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
      return make(
        parent?.id,
        r.country.isNotEmpty ? r.country : (city?.$2 ?? ''),
      );
  }
}

class _AddPlaceSheet extends StatefulWidget {
  const _AddPlaceSheet({
    required this.travelStore,
    required this.placeSearch,
    this.near,
    this.under,
  });

  final TravelStore travelStore;
  final PlaceSearch placeSearch;
  final Place? near;
  final Place? under;

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
      under: widget.under,
    );
    if (mounted) Navigator.of(context).pop(place);
  }

  /// The typed name as an area of [_AddPlaceSheet.under], at its spot: a
  /// neighbourhood or a campus MapKit doesn't know by that name.
  Future<void> _addArea(Place under) async {
    final name = _query.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    final place = await widget.travelStore.createPlace(
      name: name,
      kind: PlaceKind.area,
      lat: under.lat,
      lng: under.lng,
      parentId: under.id,
      country: under.country,
    );
    if (mounted) Navigator.of(context).pop(place);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final height = MediaQuery.sizeOf(context).height * 0.8;
    final under = widget.under;
    final typed = _query.text.trim();
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
                        placeholder: under == null
                            ? l10n.travelSearchPlaceholder
                            : l10n.placeSearchInside(under.name),
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
                child: ListView(
                  children: [
                    for (final (i, r) in _results.indexed)
                      CupertinoListTile(
                        key: ValueKey('travelSearchResult-$i'),
                        leading: Icon(
                          placeIcon(r.kind),
                          color: CupertinoColors.systemTeal,
                        ),
                        title: Text(r.name),
                        subtitle: Text(
                          [
                            if (r.category.isNotEmpty) r.category,
                            if (r.address.isNotEmpty) r.address,
                            if (r.locality.isNotEmpty && r.locality != r.name)
                              r.locality,
                            if (r.country.isNotEmpty && r.country != r.name)
                              r.country,
                          ].join(', '),
                        ),
                        additionalInfo: Text(placeKindLabel(l10n, r.kind)),
                        onTap: _saving ? null : () => _pick(r),
                      ),
                    if (_results.isEmpty &&
                        !_searching &&
                        typed.isNotEmpty &&
                        under == null)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            l10n.travelSearchNoResults,
                            style: const TextStyle(
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                        ),
                      ),
                    if (under != null && typed.isNotEmpty && !_searching)
                      CupertinoListTile(
                        key: const ValueKey('placeAddArea'),
                        leading: const Icon(
                          CupertinoIcons.add_circled,
                          color: CupertinoColors.activeBlue,
                        ),
                        title: Text(
                          l10n.placeAddAreaNamed(typed, under.name),
                          style: const TextStyle(
                            color: CupertinoColors.activeBlue,
                          ),
                        ),
                        onTap: _saving ? null : () => _addArea(under),
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
