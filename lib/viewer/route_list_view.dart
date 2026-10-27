import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../photos/place_search.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record_store.dart';
import 'route_editor_screen.dart';
import 'route_screen.dart';

/// The Routes segment of the Travel screen: a card per route, newest
/// first. Not scrollable on its own; the screen around it scrolls.
class RouteListView extends StatefulWidget {
  const RouteListView({
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
  State<RouteListView> createState() => _RouteListViewState();
}

class _RouteListViewState extends State<RouteListView> {
  List<TravelRoute> _routes = const [];
  Map<String, RouteOutline> _outlines = const {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final routes = await widget.travelStore.routes();
    final outlines = await widget.travelStore.routeOutlines();
    if (!mounted) return;
    setState(() {
      _routes = routes;
      _outlines = outlines;
      _loaded = true;
    });
  }

  Future<void> _new() async {
    final route = await widget.travelStore.createRoute(title: '');
    if (!mounted) return;
    await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => RouteEditorScreen(
          travelStore: widget.travelStore,
          placeSearch: widget.placeSearch,
          routeId: route.id,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
          isNew: true,
        ),
      ),
    );
    await _load();
  }

  Future<void> _open(TravelRoute route) async {
    await Navigator.of(context).push<void>(
      CupertinoPageRoute(
        builder: (_) => RouteScreen(
          travelStore: widget.travelStore,
          placeSearch: widget.placeSearch,
          routeId: route.id,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: CupertinoActivityIndicator(),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: CupertinoButton(
            key: const ValueKey('routeNew'),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            onPressed: _new,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(CupertinoIcons.plus, size: 18),
                const SizedBox(width: 4),
                Text(l10n.routeNew),
              ],
            ),
          ),
        ),
        if (_routes.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
            child: Text(
              l10n.routesEmpty,
              textAlign: TextAlign.center,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
          ),
        for (final r in _routes)
          _RouteCard(
            key: ValueKey('routeCard-${r.id}'),
            route: r,
            outline: _outlines[r.id] ?? const RouteOutline(),
            placeSearch: widget.placeSearch,
            onTap: () => _open(r),
          ),
      ],
    );
  }
}

class _RouteCard extends StatefulWidget {
  const _RouteCard({
    super.key,
    required this.route,
    required this.outline,
    required this.placeSearch,
    required this.onTap,
  });

  final TravelRoute route;
  final RouteOutline outline;
  final PlaceSearch placeSearch;
  final VoidCallback onTap;

  @override
  State<_RouteCard> createState() => _RouteCardState();
}

class _RouteCardState extends State<_RouteCard> {
  /// Snapshot paths by outline, for this run: the files are cached natively.
  static final _paths = <int, String?>{};
  String? _path;

  int get _key => Object.hash(
    Object.hashAll([for (final p in widget.outline.stops) (p.lat, p.lng)]),
    Object.hashAll(widget.outline.flights.toList()..sort()),
  );

  @override
  void initState() {
    super.initState();
    _snapshot();
  }

  @override
  void didUpdateWidget(_RouteCard old) {
    super.didUpdateWidget(old);
    if (old.outline != widget.outline) _snapshot();
  }

  Future<void> _snapshot() async {
    final key = _key;
    if (_paths.containsKey(key)) {
      _path = _paths[key];
      return;
    }
    final (pins, line) = routeMapData(
      widget.outline.stops,
      widget.outline.flights,
    );
    final path = await widget.placeSearch.snapshot(
      pins: pins,
      line: line,
      width: 360,
      height: 140,
    );
    _paths[key] = path;
    if (mounted && key == _key) setState(() => _path = path);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final route = widget.route;
    final dates = routeDates(route);
    final names = [for (final p in widget.outline.stops) p.name];
    final path = _path;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GestureDetector(
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
              context,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 140,
                  child: path == null
                      ? const ColoredBox(
                          color: CupertinoColors.systemGrey5,
                          child: Center(
                            child: Icon(
                              CupertinoIcons.map,
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                        )
                      : Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          cacheWidth: 720,
                          errorBuilder: (_, _, _) => const ColoredBox(
                            color: CupertinoColors.systemGrey5,
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        route.title.isEmpty ? l10n.routeUntitled : route.title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (dates.isNotEmpty) dates,
                          l10n.routeStopCount(names.length),
                        ].join(' · '),
                        style: const TextStyle(
                          fontSize: 13,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      if (names.isNotEmpty)
                        Text(
                          names.join(' → '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
