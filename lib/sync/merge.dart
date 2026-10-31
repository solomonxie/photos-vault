import 'hlc.dart';
import 'op.dart';
import 'segment.dart';

class Stamped {
  const Stamped(this.x, this.stamp);
  final Object? x;
  final String stamp;
}

class OrSetEntry {
  final adds = <String>{};
  final removes = <String>{};
  bool get present => adds.any((t) => !removes.contains(t));
}

class EntityState {
  EntityState(this.e, this.id);

  final String e;
  final String id;
  bool exists = false;
  final fields = <String, Stamped>{};

  /// Per text field, the ops no other op on that field has seen.
  final heads = <String, List<Op>>{};
  final sets = <String, Map<String, OrSetEntry>>{};

  List<String> members(String set) => [
    for (final m in (sets[set] ?? const {}).entries)
      if (m.value.present) m.key,
  ]..sort();
}

class Conflict {
  const Conflict(this.e, this.id, this.f, this.x, this.d, this.stamp);
  final String e;
  final String id;
  final String f;
  final Object? x;
  final String d;
  final String stamp;
}

/// The merged library: same result from the same ops in any order.
/// See `docs/design/cloud-sync/PROTOCOL.md → Merge`.
class SyncState {
  final entities = <String, EntityState>{};

  /// Highest contiguous seq applied, per device.
  final vv = <String, int>{};

  /// Highest stamp applied, for the local clock to outrank.
  Hlc seen = Hlc.zero;

  /// Keys of entities changed since the caller last cleared it: what to persist.
  final touched = <String>{};

  EntityState entity(String e, String id) {
    final key = '$e/$id';
    touched.add(key);
    return entities.putIfAbsent(key, () => EntityState(e, id));
  }

  /// Applies [s] if it is the device's next; false on a gap or a repeat.
  bool applySegment(Segment s) {
    final have = vv[s.d] ?? 0;
    if (s.seq != have + 1) return false;
    final bound = s.lastModified + maxClockLead.inMilliseconds;
    for (final op in s.ops) {
      if (op.wall > bound) continue;
      apply(op);
    }
    vv[s.d] = s.seq;
    return true;
  }

  void apply(Op op) {
    final h = Hlc.parse(op.h);
    seen = seen.receive(h);
    final ent = entity(op.e, op.id);
    switch (op.o) {
      case OpKind.add:
        ent.exists = true;
        final x = (op.x as Map?) ?? const {};
        for (final f in x.keys) {
          _setField(ent, f as String, x[f], op);
        }
      case OpKind.set:
        _setField(ent, op.f!, op.x, op);
      case OpKind.madd:
        _entry(ent, op).adds.add(op.stamp);
      case OpKind.mrem:
        _entry(ent, op).removes.addAll(op.ts);
    }
  }

  OrSetEntry _entry(EntityState ent, Op op) => ent.sets
      .putIfAbsent(op.f!, () => {})
      .putIfAbsent(op.x as String, OrSetEntry.new);

  void _setField(EntityState ent, String f, Object? x, Op op) {
    final cur = ent.fields[f];
    if (cur == null || op.stamp.compareTo(cur.stamp) > 0) {
      ent.fields[f] = Stamped(x, op.stamp);
    }
    if (!(textFields[ent.e]?.contains(f) ?? false)) return;
    final heads = ent.heads.putIfAbsent(f, () => []);
    final asField = _asSet(op, f, x);
    if (heads.any((h) => h.stamp == op.stamp || h.saw(asField))) return;
    heads
      ..removeWhere(asField.saw)
      ..add(asField);
  }

  /// An `add` touches many fields; a head is kept per field as a plain set.
  Op _asSet(Op op, String f, Object? x) => op.o == OpKind.set
      ? op
      : Op(
          h: op.h,
          d: op.d,
          seq: op.seq,
          vv: op.vv,
          e: op.e,
          id: op.id,
          o: OpKind.set,
          f: f,
          x: x,
        );

  Iterable<EntityState> get listed => entities.values.where((e) => e.exists);

  List<Conflict> conflicts() {
    final out = <Conflict>[];
    for (final ent in listed) {
      ent.heads.forEach((f, heads) {
        final winner = ent.fields[f]!.stamp;
        for (final h in heads) {
          if (h.stamp != winner) {
            out.add(Conflict(ent.e, ent.id, f, h.x, h.d, h.stamp));
          }
        }
      });
    }
    int cmp(Conflict a, Conflict b) {
      for (final c in [
        a.e.compareTo(b.e),
        a.id.compareTo(b.id),
        a.f.compareTo(b.f),
        a.stamp.compareTo(b.stamp),
      ]) {
        if (c != 0) return c;
      }
      return 0;
    }

    return out..sort(cmp);
  }
}
