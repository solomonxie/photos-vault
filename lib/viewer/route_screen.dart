import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart' show assetImage;
import 'native_map.dart';
import 'route_editor_screen.dart';

String legModeLabel(AppLocalizations l10n, LegMode mode) => switch (mode) {
  LegMode.walk => l10n.routeModeWalk,
  LegMode.drive => l10n.routeModeDrive,
  LegMode.train => l10n.routeModeTrain,
  LegMode.flight => l10n.routeModeFlight,
  LegMode.boat => l10n.routeModeBoat,
  LegMode.other => l10n.routeModeOther,
};

IconData legModeIcon(LegMode mode) => switch (mode) {
  LegMode.walk => CupertinoIcons.person,
  LegMode.drive => CupertinoIcons.car_detailed,
  LegMode.train => CupertinoIcons.tram_fill,
  LegMode.flight => CupertinoIcons.airplane,
  LegMode.boat => CupertinoIcons.drop,
  LegMode.other => CupertinoIcons.arrow_right,
};

/// "3 Mar 2024 – 9 Mar 2024", one end, or '' when undated.
String routeDates(TravelRoute route) {
  final f = DateFormat.yMMMd();
  final s = route.starts;
  final e = route.ends;
  if (s == null && e == null) return '';
  if (s == null || e == null || s == e) return f.format((s ?? e)!);
  return '${f.format(s)} – ${f.format(e)}';
}

/// Numbered pins and the line through [stops]; [flights] by leg position.
(List<MapPinData>, MapLineData?) routeMapData(
  List<Place> stops,
  Set<int> flights,
) {
  final pins = [
    for (final (i, p) in stops.indexed)
      MapPinData(
        id: '$i',
        lat: p.lat,
        lng: p.lng,
        title: p.name,
        number: i + 1,
      ),
  ];
  if (stops.length < 2) return (pins, null);
  return (
    pins,
    MapLineData(
      [for (final p in stops) (p.lat, p.lng)],
      geodesic: [
        for (var i = 0; i + 1 < stops.length; i++) flights.contains(i),
      ],
    ),
  );
}

/// One route: its map, then stop → leg → stop down the page.
class RouteScreen extends StatefulWidget {
  const RouteScreen({
    super.key,
    required this.travelStore,
    required this.placeSearch,
    required this.routeId,
    this.assetRecordStore,
    this.personStore,
    this.onOpenAsset,
  });

  final TravelStore travelStore;
  final PlaceSearch placeSearch;
  final String routeId;
  final AssetRecordStore? assetRecordStore;
  final PersonStore? personStore;
  final ValueChanged<String>? onOpenAsset;

  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  final _map = NativeMapController();
  RouteDetail? _detail;
  List<TravelLink> _links = const [];
  Map<String, Person> _people = const {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = widget.travelStore;
    final detail = await store.routeDetail(widget.routeId);
    final links = detail == null
        ? const <TravelLink>[]
        : (await store.linksFor(LinkOwner.route, [
                widget.routeId,
              ]))[widget.routeId] ??
              const <TravelLink>[];
    var people = _people;
    if (links.any((l) => l.target == LinkTarget.person) &&
        widget.personStore != null) {
      people = {for (final p in await widget.personStore!.listAll()) p.id: p};
    }
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _links = links;
      _people = people;
      _loaded = true;
    });
  }

  Future<void> _edit() async {
    final deleted = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => RouteEditorScreen(
          travelStore: widget.travelStore,
          placeSearch: widget.placeSearch,
          routeId: widget.routeId,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
        ),
      ),
    );
    if (!mounted) return;
    if (deleted == true) {
      Navigator.of(context).pop();
      return;
    }
    await _load();
  }

  void _focusStop(Place p) =>
      _map.focus(p.lat, p.lng, span: p.isCity ? 0.3 : 0.02);

  void _focusLeg(Place a, Place b) {
    final span = [
      (a.lat - b.lat).abs(),
      (a.lng - b.lng).abs(),
    ].reduce((x, y) => x > y ? x : y);
    _map.focus(
      (a.lat + b.lat) / 2,
      (a.lng + b.lng) / 2,
      span: (span * 1.6).clamp(0.01, 120),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final detail = _detail;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          detail == null
              ? ''
              : (detail.route.title.isEmpty
                    ? l10n.routeUntitled
                    : detail.route.title),
        ),
        trailing: detail == null
            ? null
            : CupertinoButton(
                key: const ValueKey('routeEdit'),
                padding: EdgeInsets.zero,
                onPressed: _edit,
                child: Text(l10n.routeEdit),
              ),
      ),
      child: SafeArea(
        child: !_loaded
            ? const Center(child: CupertinoActivityIndicator())
            : detail == null
            ? Center(child: Text(l10n.routeNotFound))
            : _body(l10n, detail),
      ),
    );
  }

  Widget _body(AppLocalizations l10n, RouteDetail detail) {
    final stops = [for (final s in detail.stops) detail.places[s.placeId]]
        .whereType<Place>()
        .toList();
    final flights = {
      for (final (i, l) in detail.legs.indexed)
        if (l.mode == LegMode.flight) i,
    };
    final (pins, line) = routeMapData(stops, flights);
    final dates = routeDates(detail.route);
    final photos = [
      for (final l in _links)
        if (l.target == LinkTarget.asset) l.id,
    ];
    final people = [
      for (final l in _links)
        if (l.target == LinkTarget.person && _people[l.id] != null)
          _people[l.id]!,
    ];
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 300,
            child: NativeMap(
              pins: pins,
              line: line,
              controller: _map,
              onPinTap: (id) {
                final i = int.tryParse(id);
                if (i != null && i < stops.length) _focusStop(stops[i]);
              },
            ),
          ),
        ),
        if (dates.isNotEmpty || detail.route.note.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (dates.isNotEmpty)
                    Text(
                      dates,
                      style: const TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                  if (detail.route.note.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(detail.route.note),
                  ],
                ],
              ),
            ),
          ),
        if (detail.stops.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.routeNoStops,
                textAlign: TextAlign.center,
                style: const TextStyle(color: CupertinoColors.systemGrey),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverList.builder(
            itemCount: detail.stops.length,
            itemBuilder: (context, i) {
              final stop = detail.stops[i];
              final place = detail.places[stop.placeId];
              final next = i + 1 < detail.stops.length
                  ? detail.places[detail.stops[i + 1].placeId]
                  : null;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StopRow(
                    key: ValueKey('routeStop-$i'),
                    number: i + 1,
                    stop: stop,
                    place: place,
                    last: i == detail.stops.length - 1,
                    onTap: place == null ? null : () => _focusStop(place),
                  ),
                  if (i < detail.legs.length)
                    _LegRow(
                      key: ValueKey('routeLeg-$i'),
                      leg: detail.legs[i],
                      onTap: place == null || next == null
                          ? null
                          : () => _focusLeg(place, next),
                    ),
                ],
              );
            },
          ),
        ),
        if (photos.isNotEmpty) ...[
          _header(l10n.routePhotos),
          SliverToBoxAdapter(child: _photoStrip(photos)),
        ],
        if (people.isNotEmpty) ...[
          _header(l10n.routePeople),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final p in people) RouteChip(p.name)],
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _header(String title) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
    ),
  );

  Widget _photoStrip(List<String> ids) {
    final records = widget.assetRecordStore?.visibleById;
    final shown = [for (final id in ids) ?records?[id]];
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: shown.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (context, i) => GestureDetector(
          onTap: widget.onOpenAsset == null
              ? null
              : () => widget.onOpenAsset!(shown[i].localId),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox.square(
              dimension: 96,
              child: assetImage(
                shown[i],
                thumbnailSize: 200,
                placeholder: () =>
                    const ColoredBox(color: CupertinoColors.systemGrey5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RouteChip extends StatelessWidget {
  const RouteChip(this.text, {super.key, this.onDelete});

  final String text;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: const TextStyle(fontSize: 14)),
        if (onDelete != null) ...[
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onDelete,
            child: const Icon(
              CupertinoIcons.xmark_circle_fill,
              size: 16,
              color: CupertinoColors.systemGrey,
            ),
          ),
        ],
      ],
    ),
  );
}

class _StopRow extends StatelessWidget {
  const _StopRow({
    super.key,
    required this.number,
    required this.stop,
    required this.place,
    required this.last,
    this.onTap,
  });

  final int number;
  final RouteStop stop;
  final Place? place;
  final bool last;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final arrived = stop.arrived;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 32,
              child: Column(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: CupertinoColors.activeBlue,
                    ),
                    child: Text(
                      '$number',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.white,
                      ),
                    ),
                  ),
                  if (!last) const Expanded(child: _Rail()),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 3, bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      place?.name ?? '',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (arrived != null || (place?.country ?? '').isNotEmpty)
                      Text(
                        [
                          if (arrived != null)
                            DateFormat.yMMMd().format(arrived),
                          if ((place?.country ?? '').isNotEmpty) place!.country,
                        ].join(' · '),
                        style: const TextStyle(
                          fontSize: 12,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    if (stop.note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(stop.note, style: const TextStyle(fontSize: 14)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail();

  @override
  Widget build(BuildContext context) => Container(
    width: 2,
    color: CupertinoColors.systemGrey.withValues(alpha: 0.4),
  );
}

class _LegRow extends StatelessWidget {
  const _LegRow({super.key, required this.leg, this.onTap});

  final RouteLeg leg;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(width: 32, child: Center(child: _Rail())),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          legModeIcon(leg.mode),
                          size: 15,
                          color: CupertinoColors.systemGrey,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          legModeLabel(l10n, leg.mode),
                          style: const TextStyle(
                            fontSize: 13,
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                        if (leg.needsReview) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            CupertinoIcons.exclamationmark_triangle_fill,
                            key: ValueKey('routeLegReview'),
                            size: 14,
                            color: CupertinoColors.systemOrange,
                          ),
                        ],
                      ],
                    ),
                    if (leg.note.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        leg.note,
                        style: const TextStyle(
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                    if (leg.needsReview)
                      Text(
                        l10n.routeLegReview,
                        style: const TextStyle(
                          fontSize: 12,
                          color: CupertinoColors.systemOrange,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
