import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'native_map.dart';
import 'place_screen.dart';
import 'place_tree.dart';

/// Footprints → Places (`docs/design/travel-diary.md`): every place at once,
/// country → city from the photos' own locations, hand-made pins under
/// their city; or every place as a pin on a map. Past [shownCities] a
/// country's cities fold. Every row opens its place page.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({
    super.key,
    required this.travelStore,
    required this.placeSearch,
    this.assetRecordStore,
    this.personStore,
    this.placeGroups = const {},
  });

  static const shownCities = 5;

  final TravelStore travelStore;
  final PlaceSearch placeSearch;
  final AssetRecordStore? assetRecordStore;
  final PersonStore? personStore;

  /// Photos by place name, as the library already grouped them.
  final Map<String, List<AssetRecord>> placeGroups;

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

enum PlacesSort { photos, recent, name }

class _PlacesScreenState extends State<PlacesScreen> {
  bool _loaded = false;
  List<PlaceNode> _tree = const [];
  List<MapPinData> _pins = const [];
  PlaceTally _tally = const PlaceTally({}, {});
  Map<String, String> _regions = const {};

  /// Per node, its newest photo: the cover, and the "Recent Visit" order.
  /// One pass over the place groups per load, never in `build`.
  final Map<PlaceNode, AssetRecord> _newest = {};

  /// The tree as shown: sorted and filtered, worked out when either changes.
  List<PlaceNode> _shown = const [];

  /// Search matches, flat, with their country: shown instead of the tree.
  List<(PlaceNode, PlaceNode)> _found = const [];

  PlacesSort _sort = PlacesSort.photos;
  bool _withNotes = false;
  final _search = TextEditingController();

  /// The row a map pin was tapped for; a second tap opens it.
  String? _highlight;
  final _sheet = DraggableScrollableController();
  final _rowKeys = <String, GlobalKey>{};

  /// Countries showing all their cities, by name.
  final Set<String> _unfolded = {};

  static const _peek = 0.14;
  static const _half = 0.55;

  @override
  void initState() {
    super.initState();
    _load();
    widget.placeSearch.regionCodes().then((r) {
      if (mounted) setState(() => _regions = r);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _sheet.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final places = await widget.travelStore.places();
    final counts = await widget.travelStore.entryCountsByPlace();
    if (!mounted) return;
    final tree = placeTree(places);
    final built = buildPlaceTree(widget.placeGroups, places);
    _newest.clear();
    final pins = <MapPinData>[];
    for (final country in built) {
      for (final (node, _) in country.walk()) {
        AssetRecord? newest;
        AssetRecord? located;
        for (final r in node.records) {
          if (newest == null || r.createdAt.isAfter(newest.createdAt)) {
            newest = r;
          }
          if (located == null && r.latitude != null && r.longitude != null) {
            located = r;
          }
        }
        if (newest != null) _newest[node] = newest;
        if (node.level == PlaceLevel.country) continue;
        final saved = node.place;
        final at = saved != null
            ? (saved.lat, saved.lng)
            : located == null
            ? null
            : (located.latitude!, located.longitude!);
        if (at == null) continue;
        pins.add(
          MapPinData(
            id: _keyOf(node),
            lat: at.$1,
            lng: at.$2,
            title: node.name,
          ),
        );
      }
    }
    setState(() {
      _loaded = true;
      _tree = built;
      _tally = PlaceTally.of(tree, counts);
      _pins = pins;
      _arrange();
    });
  }

  String _keyOf(PlaceNode node) => node.level == PlaceLevel.pin
      ? 'place-pin-${node.place?.id ?? node.name}'
      : 'place-${node.level.name}-${node.name}';

  int _notes(PlaceNode node) =>
      node.place == null ? 0 : _tally.impressions[node.place!.id] ?? 0;

  bool _hasNotes(PlaceNode node) => node.walk().any((e) => _notes(e.$1) > 0);

  /// Sort and filter into [_shown], search into [_found]. Call in setState.
  void _arrange() {
    int order(PlaceNode a, PlaceNode b) => switch (_sort) {
      PlacesSort.photos => b.records.length.compareTo(a.records.length),
      PlacesSort.recent =>
        (_newest[b]?.createdAt.millisecondsSinceEpoch ?? 0).compareTo(
          _newest[a]?.createdAt.millisecondsSinceEpoch ?? 0,
        ),
      PlacesSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    };
    List<PlaceNode> arranged(List<PlaceNode> list) {
      final kept = [
        for (final n in list)
          if (!_withNotes || _hasNotes(n)) n,
      ];
      if (_sort != PlacesSort.photos) kept.sort(order);
      return kept;
    }

    _shown = arranged(_tree);
    final q = _search.text.trim().toLowerCase();
    _found = q.isEmpty
        ? const []
        : [
            for (final country in _tree)
              for (final (node, _) in country.walk())
                if (node.name.toLowerCase().contains(q) &&
                    (!_withNotes || _hasNotes(node)))
                  (node, country),
          ];
    _children = {
      for (final country in _tree)
        for (final (node, _) in country.walk())
          if (node.children.isNotEmpty) node: arranged(node.children),
    };
  }

  /// [_arrange]'s children per node.
  Map<PlaceNode, List<PlaceNode>> _children = const {};

  List<PlaceNode> _kids(PlaceNode n) => _children[n] ?? const [];

  Iterable<(PlaceNode, int)> _walk(PlaceNode n, [int depth = 0]) sync* {
    yield (n, depth);
    for (final c in _kids(n)) {
      yield* _walk(c, depth + 1);
    }
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

  /// A country or city from the photos alone is saved on first open, at
  /// the middle of its photos, so it has a page to hold notes and pins.
  Future<void> _openNode(PlaceNode node, PlaceNode? country) async {
    if (node.place case final saved?) return _open(saved.id);
    var lat = 0.0, lng = 0.0, n = 0;
    for (final r in node.records) {
      final (la, lo) = (r.latitude, r.longitude);
      if (la == null || lo == null) continue;
      lat += la;
      lng += lo;
      n++;
    }
    if (n > 0) (lat, lng) = (lat / n, lng / n);
    final store = widget.travelStore;
    final place = node.level == PlaceLevel.country
        ? await store.findOrCreateCountry(node.name, lat: lat, lng: lng)
        : await store.findOrCreateCity(
            name: node.name,
            country: country?.name ?? '',
            lat: lat,
            lng: lng,
          );
    if (place == null || !mounted) return;
    await _open(place.id);
  }

  /// First tap: its row comes into view, marked. The same pin again opens it.
  Future<void> _pinTapped(String key) async {
    for (final country in _tree) {
      for (final (node, _) in country.walk()) {
        if (_keyOf(node) != key) continue;
        if (_highlight == key) return _openNode(node, country);
        setState(() {
          _highlight = key;
          _search.clear();
          _arrange();
          _unfolded.add(country.name);
        });
        if (_sheet.isAttached && _sheet.size < _half) {
          await _sheet.animateTo(
            _half,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
        await WidgetsBinding.instance.endOfFrame;
        final row = _rowKeys[key]?.currentContext;
        if (row != null && row.mounted) {
          await Scrollable.ensureVisible(
            row,
            alignment: 0.2,
            duration: const Duration(milliseconds: 250),
          );
        }
        return;
      }
    }
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

  Future<void> _pickSort() async {
    final l10n = AppLocalizations.of(context)!;
    Widget option(PlacesSort sort, String label) => CupertinoActionSheetAction(
      key: ValueKey('placesSort-${sort.name}'),
      onPressed: () {
        Navigator.of(context).pop();
        setState(() {
          _sort = sort;
          _arrange();
        });
      },
      child: Text(_sort == sort ? '✓ $label' : label),
    );
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        actions: [
          option(PlacesSort.photos, l10n.placesSortPhotos),
          option(PlacesSort.recent, l10n.placesSortRecent),
          option(PlacesSort.name, l10n.placesSortName),
          CupertinoActionSheetAction(
            key: const ValueKey('placesWithNotes'),
            onPressed: () {
              Navigator.of(sheet).pop();
              setState(() {
                _withNotes = !_withNotes;
                _arrange();
              });
            },
            child: Text(
              _withNotes
                  ? '✓ ${l10n.placesWithImpressions}'
                  : l10n.placesWithImpressions,
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  /// The rows under [country]: its first [PlacesScreen.shownCities]
  /// cities (with their pins), the fold, then pins filed on it directly.
  List<Widget> _countryRows(AppLocalizations l10n, PlaceNode country) {
    final kids = _kids(country);
    final cities = [
      for (final c in kids)
        if (c.level == PlaceLevel.city) c,
    ];
    final open = _unfolded.contains(country.name);
    final shown = open
        ? cities
        : cities.take(PlacesScreen.shownCities).toList();
    final hiddenCount = cities.length - shown.length;
    return [
      _row(l10n, country, 0, country),
      for (final city in shown)
        for (final (node, depth) in _walk(city, 1))
          _row(l10n, node, depth, country),
      if (cities.length > PlacesScreen.shownCities)
        CupertinoListTile(
          key: ValueKey('place-fold-${country.name}'),
          padding: const EdgeInsetsDirectional.only(start: 42, end: 14),
          title: Text(
            open ? l10n.placesShowFewer : l10n.placesShowMore(hiddenCount),
            style: const TextStyle(color: CupertinoColors.activeBlue),
          ),
          trailing: Icon(
            open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
            size: 16,
            color: CupertinoColors.activeBlue,
          ),
          onTap: () => setState(() {
            if (!_unfolded.remove(country.name)) _unfolded.add(country.name);
          }),
        ),
      for (final pin in kids)
        if (pin.level == PlaceLevel.pin)
          for (final (node, depth) in _walk(pin, 1))
            _row(l10n, node, depth, country),
    ];
  }

  Widget _leading(PlaceNode node) {
    if (node.level == PlaceLevel.country) {
      final flag = flagOf(_regions[node.name.toLowerCase()]);
      return flag.isEmpty
          ? const Icon(
              CupertinoIcons.flag_fill,
              color: CupertinoColors.systemTeal,
            )
          : Text(flag, style: const TextStyle(fontSize: 24));
    }
    if (node.level == PlaceLevel.city) {
      if (_newest[node] case final cover?) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: AssetTile(record: cover, extent: 34, onTap: () {}),
        );
      }
      return const Icon(
        CupertinoIcons.building_2_fill,
        color: CupertinoColors.systemTeal,
      );
    }
    return const Icon(CupertinoIcons.map_pin, color: CupertinoColors.systemRed);
  }

  Widget _row(
    AppLocalizations l10n,
    PlaceNode node,
    int depth,
    PlaceNode country, {
    String? context,
  }) {
    final saved = node.place;
    final pin = node.level == PlaceLevel.pin ? saved : null;
    final notes = _notes(node);
    final sub = [
      ?context,
      if (pin != null && pin.category.isNotEmpty) pin.category,
      if (pin != null && pin.address.isNotEmpty) pin.address,
    ].join(' · ');
    final key = _keyOf(node);
    final marked = _highlight == key;
    return KeyedSubtree(
      key: _rowKeys.putIfAbsent(key, GlobalKey.new),
      child: CupertinoListTile(
        key: ValueKey(key),
        backgroundColor: marked
            ? CupertinoColors.systemYellow.withValues(alpha: 0.18)
            : null,
        padding: EdgeInsetsDirectional.only(start: 16.0 + depth * 22, end: 14),
        leadingSize: 34,
        leading: _leading(node),
        title: Text(
          node.name,
          style: node.level == PlaceLevel.country
              ? const TextStyle(fontWeight: FontWeight.w600)
              : null,
        ),
        subtitle: sub.isEmpty ? null : Text(sub),
        additionalInfo: Text(
          [
            if (notes > 0) '❝ $notes',
            if (pin == null) '${node.records.length}',
          ].join('  '),
        ),
        trailing: const CupertinoListTileChevron(),
        onTap: () => _openNode(node, country),
      ),
    );
  }

  Widget _list(AppLocalizations l10n, ScrollController scroll) {
    final searching = _search.text.trim().isNotEmpty;
    return SingleChildScrollView(
      controller: scroll,
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey3.resolveFrom(context),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: CupertinoSearchTextField(
                    key: const ValueKey('placesSearch'),
                    controller: _search,
                    placeholder: l10n.placesSearch,
                    onChanged: (_) => setState(_arrange),
                    onTap: () {
                      if (_sheet.isAttached && _sheet.size < _half) {
                        _sheet.animateTo(
                          1,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        );
                      }
                    },
                  ),
                ),
                CupertinoButton(
                  key: const ValueKey('placesSort'),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  onPressed: _pickSort,
                  child: Icon(
                    CupertinoIcons.arrow_up_arrow_down,
                    color: _withNotes || _sort != PlacesSort.photos
                        ? CupertinoColors.activeOrange
                        : null,
                  ),
                ),
              ],
            ),
          ),
          if (_tree.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(
                    l10n.travelPlacesEmpty,
                    key: const ValueKey('travelPlacesEmpty'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                  const SizedBox(height: 12),
                  CupertinoButton.filled(
                    key: const ValueKey('placesEmptyAdd'),
                    onPressed: _add,
                    child: Text(l10n.placesAddFirst),
                  ),
                ],
              ),
            )
          else if (searching)
            _found.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.placesNoMatch,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: CupertinoColors.systemGrey),
                    ),
                  )
                : CupertinoListSection.insetGrouped(
                    children: [
                      for (final (node, country) in _found)
                        _row(
                          l10n,
                          node,
                          0,
                          country,
                          context: node == country ? null : country.name,
                        ),
                    ],
                  )
          else if (_shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.placesNoMatch,
                textAlign: TextAlign.center,
                style: const TextStyle(color: CupertinoColors.systemGrey),
              ),
            )
          else
            CupertinoListSection.insetGrouped(
              children: [
                for (final country in _shown) ..._countryRows(l10n, country),
              ],
            ),
        ],
      ),
    );
  }

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
            : Stack(
                children: [
                  Positioned.fill(
                    child: NativeMap(
                      pins: _pins,
                      onPinTap: _pinTapped,
                      onLongPress: _dropPin,
                    ),
                  ),
                  DraggableScrollableSheet(
                    controller: _sheet,
                    initialChildSize: _half,
                    minChildSize: _peek,
                    snap: true,
                    snapSizes: const [_peek, _half],
                    builder: (context, scroll) => DecoratedBox(
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemGroupedBackground
                            .resolveFrom(context),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(14),
                        ),
                        boxShadow: const [
                          BoxShadow(color: Color(0x33000000), blurRadius: 12),
                        ],
                      ),
                      child: _list(l10n, scroll),
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

  /// The typed name as a pin in [_AddPlaceSheet.under], at its spot: a
  /// neighbourhood or a campus MapKit doesn't know by that name; its
  /// description says how far it reaches.
  Future<void> _addArea(Place under) async {
    final name = _query.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    final place = await widget.travelStore.createPlace(
      name: name,
      kind: PlaceKind.point,
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
