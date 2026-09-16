import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';

/// Net graph of every [Person] and how they relate (T7.6) — hand-rolled
/// (no graph-layout package, see DESIGN.md): family-type relationships
/// (family/spouse/parent/child/sibling) cluster their members into a small
/// circle: "a family is in a circle group" per the request. Other relation
/// types are drawn as plain lines between clusters, styled by type.
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
  List<Person> _people = const [];
  List<PersonRelationship> _relationships = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final people = await widget.personStore.listAll();
    final relationships = await widget.personStore.allRelationships();
    if (!mounted) return;
    setState(() {
      _people = people;
      _relationships = relationships;
    });
  }

  /// Union-find over family-type edges only — each resulting set becomes one
  /// circle cluster in the layout.
  List<List<Person>> _familyClusters() {
    final parent = {for (final p in _people) p.id: p.id};
    String find(String id) {
      while (parent[id] != id) {
        parent[id] = parent[parent[id]!]!;
        id = parent[id]!;
      }
      return id;
    }

    void union(String a, String b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[ra] = rb;
    }

    for (final r in _relationships) {
      if (isFamilyRelationship(r.type)) union(r.personId, r.relatedPersonId);
    }

    final clusters = <String, List<Person>>{};
    for (final p in _people) {
      clusters.putIfAbsent(find(p.id), () => []).add(p);
    }
    return clusters.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final clusters = _familyClusters();
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.personGraphTitle),
      ),
      child: SafeArea(
        child: _people.length < 2
            ? Center(
                child: Text(
                  l10n.personGraphEmpty,
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) => InteractiveViewer(
                  boundaryMargin: const EdgeInsets.all(200),
                  minScale: 0.5,
                  maxScale: 4,
                  child: _GraphLayout(
                    clusters: clusters,
                    relationships: _relationships,
                    focusPersonId: widget.focusPersonId,
                    assetRecordStore: widget.assetRecordStore,
                    personStore: widget.personStore,
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                  ),
                ),
              ),
      ),
    );
  }
}

class _GraphLayout extends StatelessWidget {
  const _GraphLayout({
    required this.clusters,
    required this.relationships,
    required this.focusPersonId,
    required this.assetRecordStore,
    required this.personStore,
    required this.size,
  });

  final List<List<Person>> clusters;
  final List<PersonRelationship> relationships;
  final String? focusPersonId;
  final AssetRecordStore assetRecordStore;
  final PersonStore personStore;
  final Size size;

  static const _nodeSize = 56.0;

  Map<String, Offset> _positions() {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = math.min(size.width, size.height) / 2 - _nodeSize;
    final positions = <String, Offset>{};
    for (var i = 0; i < clusters.length; i++) {
      final angle = 2 * math.pi * i / clusters.length;
      final clusterCenter = clusters.length == 1
          ? center
          : center + Offset(math.cos(angle), math.sin(angle)) * outerRadius;
      final members = clusters[i];
      if (members.length == 1) {
        positions[members.first.id] = clusterCenter;
        continue;
      }
      final innerRadius = _nodeSize * 0.9;
      for (var j = 0; j < members.length; j++) {
        final memberAngle = 2 * math.pi * j / members.length;
        positions[members[j].id] =
            clusterCenter +
            Offset(math.cos(memberAngle), math.sin(memberAngle)) * innerRadius;
      }
    }
    return positions;
  }

  @override
  Widget build(BuildContext context) {
    final positions = _positions();
    final seen = <String>{};
    return Stack(
      children: [
        CustomPaint(
          size: size,
          painter: _EdgePainter(
            positions: positions,
            relationships: relationships.where((r) {
              final key = ([r.personId, r.relatedPersonId]..sort()).join('|');
              return seen.add(key);
            }).toList(),
            clusters: clusters,
          ),
        ),
        for (final cluster in clusters)
          for (final person in cluster)
            if (positions[person.id] case final pos?)
              Positioned(
                left: pos.dx - _nodeSize / 2,
                top: pos.dy - _nodeSize / 2,
                width: _nodeSize,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    CupertinoPageRoute(
                      builder: (_) => PersonPageScreen(
                        person: person,
                        personStore: personStore,
                        assetRecordStore: assetRecordStore,
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        decoration: person.id == focusPersonId
                            ? BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: CupertinoColors.activeBlue,
                                  width: 2,
                                ),
                              )
                            : null,
                        padding: const EdgeInsets.all(2),
                        child: PersonAvatar(
                          assetRecordStore: assetRecordStore,
                          localId: person.avatarLocalId,
                          face: person.avatarFace,
                          size: _nodeSize - 4,
                        ),
                      ),
                      Text(
                        person.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
      ],
    );
  }
}

class _EdgePainter extends CustomPainter {
  const _EdgePainter({
    required this.positions,
    required this.relationships,
    required this.clusters,
  });

  final Map<String, Offset> positions;
  final List<PersonRelationship> relationships;
  final List<List<Person>> clusters;

  @override
  void paint(Canvas canvas, Size size) {
    // Faint circle behind each multi-member family cluster.
    final clusterPaint = Paint()
      ..color = const Color(0x26FFCC00)
      ..style = PaintingStyle.fill;
    for (final cluster in clusters) {
      if (cluster.length < 2) continue;
      final pts = [for (final p in cluster) positions[p.id]]
          .whereType<Offset>()
          .toList();
      if (pts.isEmpty) continue;
      final cx = pts.map((o) => o.dx).reduce((a, b) => a + b) / pts.length;
      final cy = pts.map((o) => o.dy).reduce((a, b) => a + b) / pts.length;
      final r =
          pts.map((o) => (o - Offset(cx, cy)).distance).reduce(math.max) + 36;
      canvas.drawCircle(Offset(cx, cy), r, clusterPaint);
    }

    for (final r in relationships) {
      final a = positions[r.personId];
      final b = positions[r.relatedPersonId];
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, _paintFor(r.type));
    }
  }

  Paint _paintFor(RelationshipType type) {
    final paint = Paint()..strokeWidth = 2;
    switch (type) {
      case RelationshipType.spouse:
        return paint..color = CupertinoColors.systemRed;
      case RelationshipType.family:
      case RelationshipType.parent:
      case RelationshipType.child:
      case RelationshipType.sibling:
        return paint..color = CupertinoColors.systemGrey;
      case RelationshipType.friend:
        return paint..color = CupertinoColors.systemBlue;
      case RelationshipType.colleague:
        return paint..color = CupertinoColors.systemGreen;
      case RelationshipType.schoolmate:
        return paint..color = CupertinoColors.systemOrange;
      case RelationshipType.other:
        return paint
          ..color = CupertinoColors.systemGrey2
          ..strokeWidth = 1;
    }
  }

  @override
  bool shouldRepaint(_EdgePainter oldDelegate) =>
      oldDelegate.positions != positions ||
      oldDelegate.relationships != relationships;
}
