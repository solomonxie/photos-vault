import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'route_list_view.dart';

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
