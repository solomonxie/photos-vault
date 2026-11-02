import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/route_draft.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';

/// A travel plan drafted from the photos of some days: one stop per place,
/// in the order they were taken. Nothing is saved until Save; pops the new
/// route's id.
class RouteDraftScreen extends StatefulWidget {
  const RouteDraftScreen({
    super.key,
    required this.travelStore,
    required this.assetRecordStore,
  });

  final TravelStore travelStore;
  final AssetRecordStore assetRecordStore;

  @override
  State<RouteDraftScreen> createState() => _RouteDraftScreenState();
}

class _RouteDraftScreenState extends State<RouteDraftScreen> {
  final _title = TextEditingController();
  List<AssetRecord> _records = const [];
  List<Place> _places = const [];
  List<DraftStop> _stops = const [];
  DateTime? _from;
  DateTime? _to;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final records = await widget.assetRecordStore.listAll();
    final places = await widget.travelStore.places();
    if (!mounted) return;
    // The last week of photos: most often the trip just back from.
    final newest = records.isEmpty ? DateTime.now() : records.last.createdAt;
    _records = records;
    _places = places;
    _to = DateTime(newest.year, newest.month, newest.day);
    _from = _to!.subtract(const Duration(days: 6));
    _draft();
  }

  void _draft() =>
      setState(() => _stops = draftStops(_records, _from!, _to!, _places));

  String _autoTitle() {
    if (_stops.isEmpty) return '';
    final first = _stops.first.name;
    final last = _stops.last.name;
    final year = _stops.first.arrived.year;
    return first == last ? '$first $year' : '$first – $last $year';
  }

  Future<void> _pick({required bool from}) async {
    final l10n = AppLocalizations.of(context)!;
    var picked = (from ? _from : _to) ?? DateTime.now();
    final result = await showCupertinoModalPopup<DateTime>(
      context: context,
      builder: (sheet) => Container(
        height: 300,
        color: CupertinoColors.systemBackground.resolveFrom(sheet),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                onPressed: () => Navigator.of(sheet).pop(picked),
                child: Text(l10n.travelEntryDone),
              ),
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: picked,
                maximumDate: DateTime.now(),
                onDateTimeChanged: (d) => picked = d,
              ),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    final day = DateTime(result.year, result.month, result.day);
    if (from) {
      _from = day;
      if (_to!.isBefore(day)) _to = day;
    } else {
      _to = day;
      if (_from!.isAfter(day)) _from = day;
    }
    _draft();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final store = widget.travelStore;
    final stops = <RouteStop>[];
    for (final s in _stops) {
      final id =
          s.placeId ??
          (await store.findOrCreateCity(
            name: s.name,
            country: s.country,
            lat: s.lat,
            lng: s.lng,
          )).id;
      final day = s.arrived;
      stops.add(
        RouteStop(placeId: id, arrived: DateTime(day.year, day.month, day.day)),
      );
    }
    final last = _stops.last.photos.last.createdAt;
    final route = await store.createRoute(
      title: _title.text.trim().isEmpty ? _autoTitle() : _title.text.trim(),
      starts: stops.first.arrived,
      ends: DateTime(last.year, last.month, last.day),
    );
    await store.setStops(route.id, stops);
    if (mounted) Navigator.of(context).pop(route.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final format = DateFormat.yMMMd();
    final loaded = _from != null;
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.routeDraftTitle),
        trailing: CupertinoButton(
          key: const ValueKey('routeDraftSave'),
          padding: EdgeInsets.zero,
          onPressed: _saving || _stops.isEmpty ? null : _save,
          child: Text(l10n.travelEntrySave),
        ),
      ),
      child: SafeArea(
        child: !loaded
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  CupertinoListSection.insetGrouped(
                    footer: Text(l10n.routeDraftHint),
                    children: [
                      CupertinoListTile(
                        key: const ValueKey('routeDraftFrom'),
                        title: Text(l10n.routeDraftFrom),
                        additionalInfo: Text(format.format(_from!)),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () => _pick(from: true),
                      ),
                      CupertinoListTile(
                        key: const ValueKey('routeDraftTo'),
                        title: Text(l10n.routeDraftTo),
                        additionalInfo: Text(format.format(_to!)),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () => _pick(from: false),
                      ),
                    ],
                  ),
                  if (_stops.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        l10n.routeDraftEmpty,
                        key: const ValueKey('routeDraftEmpty'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    )
                  else ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: CupertinoTextField(
                        key: const ValueKey('routeDraftName'),
                        controller: _title,
                        placeholder: _autoTitle(),
                      ),
                    ),
                    ..._days(l10n),
                  ],
                ],
              ),
      ),
    );
  }

  /// Stops under a header per day they start on.
  List<Widget> _days(AppLocalizations l10n) {
    final first = _stops.first.arrived;
    final start = DateTime(first.year, first.month, first.day);
    final byDay = <DateTime, List<DraftStop>>{};
    for (final s in _stops) {
      final d = s.arrived;
      (byDay[DateTime(d.year, d.month, d.day)] ??= []).add(s);
    }
    return [
      for (final MapEntry(key: day, value: stops) in byDay.entries)
        CupertinoListSection.insetGrouped(
          header: Text(
            l10n.routeDay(
              day.difference(start).inDays + 1,
              DateFormat.MMMd().format(day),
            ),
          ),
          children: [
            for (final s in stops)
              CupertinoListTile(
                key: ValueKey('routeDraftStop-${s.key}-${day.day}'),
                leadingSize: 44,
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: AssetTile(
                    record: s.photos.first,
                    extent: 44,
                    onTap: () {},
                  ),
                ),
                title: Text(s.name),
                subtitle: Text(
                  [
                    if (s.placeId == null) l10n.routeDraftNewPlace,
                    l10n.travelEntryPhotosCount(s.photos.length),
                  ].join(' · '),
                ),
              ),
          ],
        ),
    ];
  }
}
