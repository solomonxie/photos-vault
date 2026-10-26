import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ego_net.dart';
import '../photos/person.dart';
import '../photos/person_owner.dart';
import '../photos/person_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';
import 'person_profile_screen.dart' show relationshipTypeLabel;

/// One person's net (T7.6), hand-rolled (no graph-layout package, see
/// DESIGN.md). Everybody at once was a ring of a thousand faces and half a
/// million lines; this is a person in the middle, their ties in one ring cut
/// into sectors — family, friends, colleagues, schoolmates, others — the
/// closest dozen of each drawn and the rest behind "+N", and a few people
/// two links out. Tapping someone puts them in the middle; back goes back.
///
/// Opened without [focusPersonId] it starts from the phone's owner, or else
/// whoever has the most links.
class PersonGraphScreen extends StatefulWidget {
  const PersonGraphScreen({
    super.key,
    required this.personStore,
    required this.assetRecordStore,
    this.focusPersonId,
  });

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;
  final String? focusPersonId;

  @override
  State<PersonGraphScreen> createState() => _PersonGraphScreenState();
}

class _PersonGraphScreenState extends State<PersonGraphScreen> {
  EgoIndex? _index;
  Map<String, Person> _people = const {};
  EgoNet? _net;
  EgoLayout? _layout;
  Map<String, AssetRecord> _records = const {};
  final _history = <String>[];
  final _view = TransformationController();
  Size? _fittedFor;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final store = widget.personStore;
    final people = {for (final p in await store.listAll()) p.id: p};
    final index = EgoIndex(
      relationships: await store.allRelationships(),
      groups: await store.allGroups(),
      photosByPerson: await store.allMemberships(),
      names: {for (final p in people.values) p.id: p.name},
    );
    var center = _net?.centerId ?? widget.focusPersonId;
    if (center == null) {
      final owner = await PersonOwner(widget.assetRecordStore).id();
      center = people.containsKey(owner) ? owner : index.busiest;
    }
    if (!mounted) return;
    _index = index;
    _people = people;
    await _centerOn(center);
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _centerOn(String? id) async {
    final index = _index;
    if (index == null || id == null || !_people.containsKey(id)) {
      setState(() => _net = _layout = null);
      return;
    }
    final net = index.around(id);
    final drawn = [
      id,
      for (final g in net.groups) ...g.shown.map((t) => t.personId),
      for (final (_, other) in net.second) other,
    ];
    final records = await widget.assetRecordStore.getVisibleByLocalIds([
      for (final p in drawn) ?_people[p]?.avatarLocalId,
    ]);
    if (!mounted) return;
    setState(() {
      _net = net;
      _layout = EgoLayout.of(net);
      _records = records;
      _fittedFor = null;
    });
  }

  void _recenter(String id) {
    final current = _net?.centerId;
    if (current == null || current == id) return;
    _history.add(current);
    _centerOn(id);
  }

  Future<void> _openProfile(Person person) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonPageScreen(
          person: person,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
    if (mounted) await _load();
  }

  /// Whole net on screen, never blown up past life size.
  void _fit(Size viewport, double side) {
    if (_fittedFor == viewport) return;
    _fittedFor = viewport;
    final scale = math.min(1.0, viewport.shortestSide / side);
    // After this frame: the viewer listens to the controller.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _view.value = Matrix4.identity()
        ..translateByDouble(
          (viewport.width - side * scale) / 2,
          (viewport.height - side * scale) / 2,
          0,
          1,
        )
        ..scaleByDouble(scale, scale, 1, 1);
    });
  }

  Future<void> _showGroup(EgoGroup group) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => _GroupSheet(
        title: '${_sectorLabel(l10n, group.sector)} · ${group.total}',
        ties: group.all,
        people: _people,
        assetRecordStore: widget.assetRecordStore,
      ),
    );
    if (picked != null) _recenter(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final net = _net, layout = _layout;
    final center = net == null ? null : _people[net.centerId];
    return PopScope(
      canPop: _history.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _history.isNotEmpty) _centerOn(_history.removeLast());
      },
      child: CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(center?.name ?? l10n.personGraphTitle),
          trailing: center == null
              ? null
              : CupertinoButton(
                  key: const ValueKey('graphOpenProfile'),
                  padding: EdgeInsets.zero,
                  onPressed: () => _openProfile(center),
                  child: Text(l10n.personGraphOpenProfile),
                ),
        ),
        child: SafeArea(
          child: !_loaded
              ? const Center(child: CupertinoActivityIndicator())
              : net == null || layout == null || net.isEmpty
              ? Center(
                  child: Text(
                    l10n.personGraphEmpty,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    _fit(constraints.biggest, layout.side);
                    return InteractiveViewer(
                      transformationController: _view,
                      constrained: false,
                      boundaryMargin: const EdgeInsets.all(400),
                      minScale: 0.1,
                      maxScale: 4,
                      child: _EgoCanvas(
                        net: net,
                        layout: layout,
                        people: _people,
                        records: _records,
                        assetRecordStore: widget.assetRecordStore,
                        sectorLabel: (s) => _sectorLabel(l10n, s),
                        onPerson: (id) => id == net.centerId
                            ? _openProfile(_people[id]!)
                            : _recenter(id),
                        onMore: _showGroup,
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

String _sectorLabel(AppLocalizations l10n, EgoSector sector) =>
    switch (sector) {
      EgoSector.family => l10n.personGraphFamily,
      EgoSector.friend => l10n.personGraphFriends,
      EgoSector.colleague => l10n.personGraphColleagues,
      EgoSector.schoolmate => l10n.personGraphSchoolmates,
      EgoSector.other => l10n.personGraphOthers,
    };

Color _sectorColor(EgoSector sector) => switch (sector) {
  EgoSector.family => CupertinoColors.systemRed,
  EgoSector.friend => CupertinoColors.systemBlue,
  EgoSector.colleague => CupertinoColors.systemGreen,
  EgoSector.schoolmate => CupertinoColors.systemOrange,
  EgoSector.other => CupertinoColors.systemGrey,
};

Offset _o(Offset2 p) => Offset(p.x, p.y);

class _EgoCanvas extends StatelessWidget {
  const _EgoCanvas({
    required this.net,
    required this.layout,
    required this.people,
    required this.records,
    required this.assetRecordStore,
    required this.sectorLabel,
    required this.onPerson,
    required this.onMore,
  });

  final EgoNet net;
  final EgoLayout layout;
  final Map<String, Person> people;
  final Map<String, AssetRecord> records;
  final AssetRecordStore assetRecordStore;
  final String Function(EgoSector) sectorLabel;
  final void Function(String) onPerson;
  final void Function(EgoGroup) onMore;

  static const _node = 52.0;
  static const _centerNode = 72.0;
  static const _labelWidth = EgoLayout.slot - 6;

  Widget _at(Offset2 p, double size, Widget child) => Positioned(
    left: p.x - _labelWidth / 2,
    top: p.y - size / 2,
    width: _labelWidth,
    child: child,
  );

  Widget _person(String id, {required bool center, Color? ring}) {
    final person = people[id]!;
    final size = center ? _centerNode : _node;
    return _at(
      layout.positions[id]!,
      size,
      GestureDetector(
        key: ValueKey('graph-$id'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onPerson(id),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: center
                      ? CupertinoColors.activeBlue
                      : (ring ?? CupertinoColors.systemGrey).withValues(
                          alpha: 0.6,
                        ),
                  width: center ? 2.5 : 1.5,
                ),
              ),
              child: PersonAvatar(
                assetRecordStore: assetRecordStore,
                localId: person.avatarLocalId,
                face: person.avatarFace,
                records: records,
                size: size - 7,
              ),
            ),
            Text(
              person.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: center ? 13 : 11,
                fontWeight: center ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grey = CupertinoColors.systemGrey.resolveFrom(context);
    return SizedBox.square(
      dimension: layout.side,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _EdgePainter(net: net, layout: layout),
            ),
          ),
          for (final g in net.groups)
            if (layout.sectorLabels[g.sector] case final p?)
              Positioned(
                left: p.x - 50,
                top: p.y - 8,
                width: 100,
                child: Text(
                  sectorLabel(g.sector),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: _sectorColor(g.sector),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          for (final (_, id) in net.second) _person(id, center: false),
          for (final g in net.groups) ...[
            for (final t in g.shown)
              _person(t.personId, center: false, ring: _sectorColor(g.sector)),
            if (layout.more[g.sector] case final p?)
              _at(
                p,
                _node,
                GestureDetector(
                  key: ValueKey('graphMore-${g.sector.name}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onMore(g),
                  child: Column(
                    children: [
                      Container(
                        width: _node,
                        height: _node,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _sectorColor(g.sector).withValues(alpha: 0.15),
                          border: Border.all(
                            color: _sectorColor(g.sector)
                                .withValues(alpha: 0.6),
                            width: 1.5,
                          ),
                        ),
                        child: Text(
                          '+${g.rest.length}',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _sectorColor(g.sector),
                          ),
                        ),
                      ),
                      Text(
                        sectorLabel(g.sector),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: grey),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          _person(net.centerId, center: true),
        ],
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  const _EdgePainter({required this.net, required this.layout});

  final EgoNet net;
  final EgoLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    final center = _o(layout.positions[net.centerId]!);
    for (final g in net.groups) {
      final paint = Paint()
        ..color = _sectorColor(g.sector).withValues(alpha: 0.35)
        ..strokeWidth = 1;
      for (final t in g.shown) {
        canvas.drawLine(center, _o(layout.positions[t.personId]!), paint);
      }
      if (layout.more[g.sector] case final p?) {
        canvas.drawLine(center, _o(p), paint..strokeWidth = 0.6);
      }
    }
    final outer = Paint()
      ..color = CupertinoColors.systemGrey.withValues(alpha: 0.3)
      ..strokeWidth = 0.8;
    for (final (from, to) in net.second) {
      canvas.drawLine(
        _o(layout.positions[from]!),
        _o(layout.positions[to]!),
        outer,
      );
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.net != net || old.layout != layout;
}

/// Everyone in one sector, closest first; picking one recenters on them.
class _GroupSheet extends StatelessWidget {
  const _GroupSheet({
    required this.title,
    required this.ties,
    required this.people,
    required this.assetRecordStore,
  });

  final String title;
  final List<EgoTie> ties;
  final Map<String, Person> people;
  final AssetRecordStore assetRecordStore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPopupSurface(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: ties.length,
                itemExtent: 56,
                itemBuilder: (context, i) {
                  final tie = ties[i];
                  final person = people[tie.personId]!;
                  final detail = [
                    relationshipTypeLabel(l10n, tie.type),
                    ?tie.organization,
                  ].join(' · ');
                  return CupertinoListTile(
                    key: ValueKey('graphSheet-${tie.personId}'),
                    leading: PersonAvatar(
                      assetRecordStore: assetRecordStore,
                      localId: person.avatarLocalId,
                      face: person.avatarFace,
                      size: 36,
                    ),
                    leadingSize: 36,
                    title: Text(person.name),
                    subtitle: Text(detail),
                    onTap: () => Navigator.of(context).pop(tie.personId),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
