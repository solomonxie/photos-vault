import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record_store.dart';
import 'place_screen.dart';
import 'places_screen.dart';
import 'route_list_view.dart';
import 'travel_entry_editor.dart';

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
  Map<String, int> _photosOf = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = widget.travelStore;
    final entries = await store.entries(limit: 1000);
    final places = await store.places();
    final links = await store.linksFor(LinkOwner.entry, [
      for (final e in entries) e.id,
    ]);
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
      _photosOf = {
        for (final MapEntry(:key, :value) in links.entries)
          key: value.where((l) => l.target == LinkTarget.asset).length,
      };
    });
  }

  Future<void> _read(TravelEntry e) async {
    final changed = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => TravelEntryScreen(
          travelStore: widget.travelStore,
          entryId: e.id,
          placeName: _paths[e.placeId] ?? '',
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
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
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
        ),
      ),
    );
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
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
                  child: Text(
                    l10n.impressionsEmpty,
                    key: const ValueKey('impressionsEmpty'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  CupertinoListSection.insetGrouped(
                    children: [
                      for (final e in _entries)
                        impressionTile(
                          l10n,
                          e,
                          at: _paths[e.placeId],
                          photos: _photosOf[e.id] ?? 0,
                          onTap: () => _read(e),
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
