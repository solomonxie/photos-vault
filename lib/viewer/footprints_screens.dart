import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'place_screen.dart';
import 'places_screen.dart';
import 'route_list_view.dart';
import 'travel_entry_editor.dart';
import 'undo_toast.dart';

/// Footprints → Impressions: every one written, newest first, each with
/// the place it's about. + writes one about a place found or already
/// saved.
class ImpressionsScreen extends StatefulWidget {
  const ImpressionsScreen({
    super.key,
    required this.travelStore,
    required this.placeSearch,
    this.assetRecordStore,
    this.personStore,
  });

  final TravelStore travelStore;
  final PlaceSearch placeSearch;
  final AssetRecordStore? assetRecordStore;
  final PersonStore? personStore;

  @override
  State<ImpressionsScreen> createState() => _ImpressionsScreenState();
}

class _ImpressionsScreenState extends State<ImpressionsScreen> {
  bool _loaded = false;
  List<TravelEntry> _entries = const [];
  Map<String, String> _paths = const {};
  final _search = TextEditingController();
  final _undo = UndoToast();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _undo.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final store = widget.travelStore;
    final entries = await store.entries(limit: 1000);
    final places = await store.places();
    if (!mounted) return;
    final byId = {for (final p in places) p.id: p};
    // "Gion, Kyoto": the place and the one it's in.
    String path(String id) {
      final p = byId[id];
      if (p == null) return '';
      final up = byId[p.parentId];
      return up == null || up.isCountry ? p.name : '${p.name}, ${up.name}';
    }

    setState(() {
      _loaded = true;
      _entries = entries;
      _paths = {for (final e in entries) e.placeId: path(e.placeId)};
    });
  }

  Future<void> _read(TravelEntry e) async {
    final changed = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => TravelEntryScreen(
          travelStore: widget.travelStore,
          entryId: e.id,
          placeName: _paths[e.placeId] ?? '',
        ),
      ),
    );
    if (changed == true) await _load();
  }

  Future<void> _write() async {
    final place = await showAddPlaceSheet(
      context: context,
      travelStore: widget.travelStore,
      placeSearch: widget.placeSearch,
    );
    if (place == null || !mounted) return;
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

  Future<bool> _delete(TravelEntry e) async {
    final l10n = AppLocalizations.of(context)!;
    final store = widget.travelStore;
    final links =
        (await store.linksFor(LinkOwner.entry, [e.id]))[e.id] ??
        const <TravelLink>[];
    await store.deleteEntry(e.id);
    unawaited(HapticFeedback.mediumImpact());
    if (!mounted) return true;
    setState(() => _entries = [..._entries]..remove(e));
    _undo.show(context, l10n.footprintsDeleted, () async {
      await store.saveEntry(e);
      await store.setLinks(LinkOwner.entry, e.id, links);
      await _load();
    });
    return true;
  }

  /// Matching the search box: title, text, tags or where.
  List<TravelEntry> get _matching {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _entries;
    return [
      for (final e in _entries)
        if ('${e.title}\n${e.text}\n${e.tags.join(' ')}\n${_paths[e.placeId]}'
            .toLowerCase()
            .contains(q))
          e,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final shown = _matching;
    final byYear = <int?, List<TravelEntry>>{};
    for (final e in shown) {
      (byYear[e.at?.year] ??= []).add(e);
    }
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.footprintsImpressions),
        trailing: CupertinoButton(
          key: const ValueKey('impressionsNew'),
          padding: EdgeInsets.zero,
          onPressed: _write,
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: !_loaded
            ? const Center(child: CupertinoActivityIndicator())
            : _entries.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.impressionsEmpty,
                        key: const ValueKey('impressionsEmpty'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      const SizedBox(height: 12),
                      CupertinoButton.filled(
                        key: const ValueKey('impressionsEmptyWrite'),
                        onPressed: _write,
                        child: Text(l10n.impressionsWriteFirst),
                      ),
                    ],
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: CupertinoSearchTextField(
                      key: const ValueKey('impressionsSearch'),
                      controller: _search,
                      placeholder: l10n.impressionsSearch,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        l10n.impressionsNoMatch,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    ),
                  for (final MapEntry(key: year, value: list) in byYear.entries)
                    CupertinoListSection.insetGrouped(
                      key: ValueKey('impressionsYear-$year'),
                      header: Text(
                        year == null ? l10n.impressionsUndated : '$year',
                      ),
                      children: [
                        for (final e in list)
                          Dismissible(
                            key: ValueKey('impressionSwipe-${e.id}'),
                            direction: DismissDirection.endToStart,
                            background: const ColoredBox(
                              color: CupertinoColors.destructiveRed,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Padding(
                                  padding: EdgeInsets.only(right: 20),
                                  child: Icon(
                                    CupertinoIcons.delete,
                                    color: CupertinoColors.white,
                                  ),
                                ),
                              ),
                            ),
                            confirmDismiss: (_) => _delete(e),
                            child: impressionTile(
                              l10n,
                              e,
                              at: _paths[e.placeId],
                              onTap: () => _read(e),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
      ),
    );
  }
}

/// Footprints → Travel Plans: the routes, stop by stop.
class TravelPlansScreen extends StatelessWidget {
  const TravelPlansScreen({
    super.key,
    required this.travelStore,
    required this.placeSearch,
    this.assetRecordStore,
    this.personStore,
  });

  final TravelStore travelStore;
  final PlaceSearch placeSearch;
  final AssetRecordStore? assetRecordStore;
  final PersonStore? personStore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.footprintsPlans)),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            RouteListView(
              travelStore: travelStore,
              placeSearch: placeSearch,
              assetRecordStore: assetRecordStore,
              personStore: personStore,
            ),
          ],
        ),
      ),
    );
  }
}

/// A day in an earlier year with photos taken somewhere named, on today's
/// date: the most recent such year.
typedef PastDay = ({DateTime day, String place, List<AssetRecord> photos});

/// Of [records] (oldest first), the most recent earlier year's [today] that
/// has photos with a place, named by its most common city. A binary search
/// per year, so it never walks the library.
PastDay? onThisDay(List<AssetRecord> records, DateTime today) {
  if (records.isEmpty) return null;
  final oldest = records.first.createdAt.year;
  for (var year = today.year - 1; year >= oldest; year--) {
    final day = DateTime(year, today.month, today.day);
    if (day.month != today.month) continue;
    final end = day.add(const Duration(days: 1));
    var lo = 0;
    var hi = records.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (records[mid].createdAt.isBefore(day)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final photos = <AssetRecord>[];
    final counts = <String, int>{};
    for (var i = lo; i < records.length; i++) {
      final r = records[i];
      if (!r.createdAt.isBefore(end)) break;
      if (r.passcodeHash != null || r.deletedAt != null) continue;
      photos.add(r);
      final city = (r.location ?? '').split(',').first.trim();
      if (city.isNotEmpty) counts[city] = (counts[city] ?? 0) + 1;
    }
    if (counts.isEmpty) continue;
    final place = counts.entries
        .reduce((a, b) => b.value > a.value ? b : a)
        .key;
    return (day: day, place: place, photos: photos);
  }
  return null;
}

/// Countries and cities among the library's place names ("Kyoto, Japan").
({int countries, int cities}) placeNameCounts(Iterable<String> names) {
  final countries = <String>{};
  final cities = <String>{};
  for (final n in names) {
    final parts = [
      for (final s in n.split(','))
        if (s.trim().isNotEmpty) s.trim().toLowerCase(),
    ];
    if (parts.isEmpty) continue;
    countries.add(parts.last);
    if (parts.length > 1) {
      cities.add('${parts[parts.length - 2]}|${parts.last}');
    }
  }
  return (countries: countries.length, cities: cities.length);
}

/// The top of Library's Footprints: a map of everywhere photos were taken,
/// with how many countries and cities. Opens Places.
class FootprintsHero extends StatefulWidget {
  const FootprintsHero({
    super.key,
    required this.placeSearch,
    required this.placeGroups,
    required this.onTap,
  });

  final PlaceSearch placeSearch;
  final Map<String, List<AssetRecord>> placeGroups;
  final VoidCallback onTap;

  @override
  State<FootprintsHero> createState() => _FootprintsHeroState();
}

class _FootprintsHeroState extends State<FootprintsHero> {
  /// By the set of place names: the file itself is cached natively.
  static final _paths = <int, String?>{};
  String? _path;
  ({int countries, int cities}) _counts = (countries: 0, cities: 0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FootprintsHero old) {
    super.didUpdateWidget(old);
    if (!identical(old.placeGroups, widget.placeGroups)) _load();
  }

  Future<void> _load() async {
    final groups = widget.placeGroups;
    _counts = placeNameCounts(groups.keys);
    final key = Object.hashAllUnordered(groups.keys);
    if (_paths.containsKey(key)) {
      setState(() => _path = _paths[key]);
      return;
    }
    // One pin per place name, at its first photo with GPS: hundreds of
    // names, not the library.
    final pins = <MapPinData>[];
    for (final MapEntry(key: name, value: list) in groups.entries) {
      for (final r in list) {
        if ((r.latitude, r.longitude) case (final la?, final lo?)) {
          pins.add(MapPinData(id: name, lat: la, lng: lo));
          break;
        }
      }
    }
    final path = await widget.placeSearch.snapshot(
      pins: pins,
      width: 360,
      height: 150,
    );
    _paths[key] = path;
    if (mounted) setState(() => _path = path);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final path = _path;
    if (widget.placeGroups.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: GestureDetector(
        key: const ValueKey('footprintsHero'),
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            children: [
              AspectRatio(
                aspectRatio: 360 / 150,
                child: path == null
                    ? const ColoredBox(color: Color(0xFF2C2C2E))
                    : Image.file(File(path), fit: BoxFit.cover),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 18, 12, 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xAA000000)],
                    ),
                  ),
                  child: Text(
                    l10n.footprintsHeroCounts(
                      _counts.countries,
                      _counts.cities,
                    ),
                    style: const TextStyle(
                      color: CupertinoColors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
