import 'dart:math' as math;

import 'person.dart';

/// The relationship graph around one person, cut to what a phone can show.
///
/// A company group of a thousand makes a thousand neighbours and half a
/// million derived pairs; drawing them was the graph. Here the index is
/// built once per load from explicit links, group memberships and shared
/// photos, and [EgoIndex.around] answers one centre at a time in
/// proportion to that person's ties, never to the library.
enum EgoSector { family, friend, colleague, schoolmate, other }

EgoSector sectorOf(RelationshipType type) => switch (type) {
  RelationshipType.family ||
  RelationshipType.spouse ||
  RelationshipType.parent ||
  RelationshipType.child ||
  RelationshipType.sibling => EgoSector.family,
  RelationshipType.friend => EgoSector.friend,
  RelationshipType.colleague => EgoSector.colleague,
  RelationshipType.schoolmate => EgoSector.schoolmate,
  RelationshipType.other => EgoSector.other,
};

int _closeness(RelationshipType type) => switch (type) {
  RelationshipType.spouse => 0,
  RelationshipType.parent || RelationshipType.child => 1,
  RelationshipType.sibling => 2,
  RelationshipType.family => 3,
  _ => 4,
};

class EgoTie {
  const EgoTie({
    required this.personId,
    required this.type,
    required this.explicit,
    required this.sharedPhotos,
    this.organization,
  });

  final String personId;

  /// The closest of the links between the two.
  final RelationshipType type;

  /// Drawn by somebody, rather than implied by a shared group.
  final bool explicit;
  final int sharedPhotos;
  final String? organization;

  EgoSector get sector => sectorOf(type);
}

class EgoGroup {
  const EgoGroup(this.sector, this.shown, this.rest);

  final EgoSector sector;
  final List<EgoTie> shown;

  /// Behind the "+N" node.
  final List<EgoTie> rest;

  int get total => shown.length + rest.length;
  List<EgoTie> get all => [...shown, ...rest];
}

class EgoNet {
  const EgoNet(this.centerId, this.groups, this.second);

  final String centerId;

  /// Non-empty sectors, in [EgoSector] order.
  final List<EgoGroup> groups;

  /// Two hops out over explicit links: (ring-one person, their tie).
  final List<(String, String)> second;

  bool get isEmpty => groups.isEmpty;
}

class EgoIndex {
  EgoIndex({
    required Iterable<PersonRelationship> relationships,
    required Map<PersonGroup, List<String>> groups,
    required Map<String, List<String>> photosByPerson,
    required Map<String, String> names,
  }) : _photosOf = photosByPerson,
       // Named parameters can't be private initializing formals.
       // ignore: prefer_initializing_formals
       _names = names {
    for (final r in relationships) {
      if (r.personId == r.relatedPersonId) continue;
      (_explicit[r.personId] ??= []).add(r);
      (_explicit[r.relatedPersonId] ??= []).add(r);
    }
    for (final MapEntry(key: group, value: members) in groups.entries) {
      for (final id in members) {
        (_groupsOf[id] ??= []).add((group, members));
      }
    }
    for (final MapEntry(key: person, value: photos) in photosByPerson.entries) {
      for (final photo in photos) {
        (_peopleIn[photo] ??= []).add(person);
      }
    }
  }

  final Map<String, String> _names;
  final Map<String, List<String>> _photosOf;
  final _explicit = <String, List<PersonRelationship>>{};
  final _groupsOf = <String, List<(PersonGroup, List<String>)>>{};
  final _peopleIn = <String, List<String>>{};

  /// Most links, for a graph opened with nobody in particular.
  String? get busiest {
    String? best;
    var most = 0;
    for (final MapEntry(:key, :value) in _explicit.entries) {
      if (!_names.containsKey(key)) continue;
      if (value.length > most) (best, most) = (key, value.length);
    }
    return best;
  }

  EgoNet around(
    String center, {
    int perSector = 12,
    int secondPerPerson = 3,
    int secondMax = 36,
  }) {
    final shared = <String, int>{};
    for (final photo in _photosOf[center] ?? const <String>[]) {
      for (final other in _peopleIn[photo] ?? const <String>[]) {
        if (other != center) shared[other] = (shared[other] ?? 0) + 1;
      }
    }
    final ties = <String, EgoTie>{};
    void offer(
      String id,
      RelationshipType type,
      bool explicit,
      String? organization,
    ) {
      if (id == center || !_names.containsKey(id)) return;
      final had = ties[id];
      if (had != null) {
        if (_rank(had.explicit, had.type) <= _rank(explicit, type)) return;
      }
      ties[id] = EgoTie(
        personId: id,
        type: type,
        explicit: explicit,
        sharedPhotos: shared[id] ?? 0,
        organization: organization,
      );
    }

    for (final r in _explicit[center] ?? const <PersonRelationship>[]) {
      final other = r.personId == center ? r.relatedPersonId : r.personId;
      offer(other, r.type, true, r.organization);
    }
    for (final (group, members)
        in _groupsOf[center] ?? const <(PersonGroup, List<String>)>[]) {
      for (final id in members) {
        offer(
          id,
          relationshipForGroup(group.kind),
          false,
          group.kind == GroupKind.circle ? null : group.name,
        );
      }
    }

    final bySector = <EgoSector, List<EgoTie>>{};
    for (final tie in ties.values) {
      (bySector[tie.sector] ??= []).add(tie);
    }
    final groups = <EgoGroup>[];
    for (final sector in EgoSector.values) {
      final list = bySector[sector];
      if (list == null) continue;
      list.sort(_closer);
      final cut = math.min(perSector, list.length);
      groups.add(EgoGroup(sector, list.sublist(0, cut), list.sublist(cut)));
    }

    final second = <(String, String)>[];
    final taken = {center, ...ties.keys};
    outer:
    for (final group in groups) {
      for (final tie in group.shown) {
        final next = <(RelationshipType, String)>[];
        for (final r in _explicit[tie.personId] ?? const []) {
          final other = r.personId == tie.personId
              ? r.relatedPersonId
              : r.personId;
          if (!taken.contains(other) && _names.containsKey(other)) {
            next.add((r.type, other));
          }
        }
        next.sort(
          (a, b) => _closeness(a.$1) != _closeness(b.$1)
              ? _closeness(a.$1).compareTo(_closeness(b.$1))
              : _names[a.$2]!.compareTo(_names[b.$2]!),
        );
        for (final (_, id) in next.take(secondPerPerson)) {
          if (!taken.add(id)) continue;
          second.add((tie.personId, id));
          if (second.length >= secondMax) break outer;
        }
      }
    }
    return EgoNet(center, groups, second);
  }

  static int _rank(bool explicit, RelationshipType type) =>
      (explicit ? 0 : 10) + _closeness(type);

  int _closer(EgoTie a, EgoTie b) {
    if (a.explicit != b.explicit) return a.explicit ? -1 : 1;
    final c = _closeness(a.type).compareTo(_closeness(b.type));
    if (c != 0) return c;
    final s = b.sharedPhotos.compareTo(a.sharedPhotos);
    if (s != 0) return s;
    return _names[a.personId]!.compareTo(_names[b.personId]!);
  }
}

/// Where each drawn node sits: sectors as arcs of one ring, a "+N" node
/// closing each arc that has more, the second hop on an outer ring next to
/// whoever brought them in. Spacing is fixed in pixels so labels never
/// overlap; the rings grow instead.
class EgoLayout {
  EgoLayout._(this.side, this.positions, this.more, this.sectorLabels);

  static const slot = 76.0;

  final double side;
  final Map<String, Offset2> positions;

  /// The "+N" node of each sector that has one.
  final Map<EgoSector, Offset2> more;
  final Map<EgoSector, Offset2> sectorLabels;

  factory EgoLayout.of(EgoNet net) {
    final slots = [
      for (final g in net.groups) g.shown.length + (g.rest.isEmpty ? 0 : 1),
    ];
    const gap = 1;
    final total = slots.fold(0, (a, b) => a + b + gap);
    final r1 = math.max(150.0, total * slot / (2 * math.pi));
    final positions = <String, Offset2>{};
    final more = <EgoSector, Offset2>{};
    final labels = <EgoSector, Offset2>{};
    final angles = <String, double>{};
    var at = -math.pi / 2;
    final step = 2 * math.pi / total;
    for (final (i, g) in net.groups.indexed) {
      final start = at;
      for (final tie in g.shown) {
        angles[tie.personId] = at;
        positions[tie.personId] = Offset2.polar(r1, at);
        at += step;
      }
      if (g.rest.isNotEmpty) {
        more[g.sector] = Offset2.polar(r1, at);
        at += step;
      }
      final mid = start + (slots[i] - 1) * step / 2;
      labels[g.sector] = Offset2.polar(r1 * 0.55, mid);
      at += step * gap;
    }

    var outer = r1;
    if (net.second.isNotEmpty) {
      final want = [for (final (parent, _) in net.second) angles[parent]!];
      final r2 = math.max(r1 + 120, net.second.length * slot / (2 * math.pi));
      final minStep = slot / r2;
      final placed = List<double>.of(want);
      for (var i = 1; i < placed.length; i++) {
        placed[i] = math.max(placed[i], placed[i - 1] + minStep);
      }
      var drift = 0.0;
      for (var i = 0; i < placed.length; i++) {
        drift += placed[i] - want[i];
      }
      drift /= placed.length;
      for (final (i, (_, id)) in net.second.indexed) {
        positions[id] = Offset2.polar(r2, placed[i] - drift);
      }
      outer = r2;
    }
    positions[net.centerId] = const Offset2(0, 0);
    final side = 2 * (outer + slot);
    Offset2 shift(Offset2 o) => Offset2(o.x + side / 2, o.y + side / 2);
    return EgoLayout._(
      side,
      positions.map((k, v) => MapEntry(k, shift(v))),
      more.map((k, v) => MapEntry(k, shift(v))),
      labels.map((k, v) => MapEntry(k, shift(v))),
    );
  }
}

/// A point without dart:ui, so this file stays plain Dart.
class Offset2 {
  const Offset2(this.x, this.y);
  Offset2.polar(double r, double angle)
    : x = r * math.cos(angle),
      y = r * math.sin(angle);

  final double x;
  final double y;
}
