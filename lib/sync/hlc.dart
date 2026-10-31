/// Hybrid logical clock: `<wall:013d>-<counter:04d>`, fixed width so string
/// order is time order. See `docs/design/cloud-sync/PROTOCOL.md`.
class Hlc implements Comparable<Hlc> {
  const Hlc(this.wall, this.counter);

  final int wall;
  final int counter;

  static const zero = Hlc(0, 0);

  static Hlc parse(String s) {
    final dash = s.indexOf('-');
    return Hlc(
      int.parse(s.substring(0, dash)),
      int.parse(s.substring(dash + 1)),
    );
  }

  /// The next local stamp, never behind [this] whatever [now] says.
  Hlc tick(int now) => now > wall ? Hlc(now, 0) : Hlc(wall, counter + 1);

  /// Folds in a stamp seen from another device, so the next [tick] outranks it.
  Hlc receive(Hlc seen) => compareTo(seen) >= 0 ? this : seen;

  @override
  int compareTo(Hlc other) => wall != other.wall
      ? wall.compareTo(other.wall)
      : counter.compareTo(other.counter);

  @override
  bool operator ==(Object other) =>
      other is Hlc && other.wall == wall && other.counter == counter;

  @override
  int get hashCode => Object.hash(wall, counter);

  @override
  String toString() =>
      '${wall.toString().padLeft(13, '0')}-${counter.toString().padLeft(4, '0')}';
}

/// Ops stamped further than this past their segment's server `LastModified`
/// are ignored by every reader alike.
const maxClockLead = Duration(hours: 1);
