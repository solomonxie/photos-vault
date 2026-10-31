import 'hlc.dart';

enum OpKind { add, set, madd, mrem }

/// One change to one entity. [d], [seq] and [vv] come from the segment that
/// carries it.
class Op {
  Op({
    required this.h,
    required this.d,
    required this.seq,
    required this.vv,
    required this.e,
    required this.id,
    required this.o,
    this.f,
    this.x,
    this.ts = const [],
  });

  final String h;
  final String d;
  final int seq;
  final Map<String, int> vv;
  final String e;
  final String id;
  final OpKind o;
  final String? f;
  final Object? x;
  final List<String> ts;

  String get stamp => '$h@$d';
  int get wall => Hlc.parse(h).wall;

  /// Whether this op was made knowing [other]. Seen implies a greater stamp.
  bool saw(Op other) => d == other.d
      ? stamp.compareTo(other.stamp) > 0
      : (vv[other.d] ?? 0) >= other.seq;

  factory Op.fromJson(
    Map<String, Object?> j, {
    required String d,
    required int seq,
    required Map<String, int> vv,
  }) => Op(
    h: j['h'] as String,
    d: d,
    seq: seq,
    vv: vv,
    e: j['e'] as String,
    id: j['id'] as String,
    o: OpKind.values.byName(j['o'] as String),
    f: j['f'] as String?,
    x: j['x'],
    ts: [...?(j['ts'] as List?)?.cast<String>()],
  );

  Map<String, Object?> toJson() => {
    'h': h,
    'e': e,
    'id': id,
    'o': o.name,
    if (f != null) 'f': f,
    if (o != OpKind.add || x != null) 'x': x,
    if (o == OpKind.mrem) 'ts': ts,
  };
}

/// Text fields keep every concurrent value as a conflict instead of
/// dropping the LWW loser.
const textFields = {
  'asset': {'description', 'location'},
  'album': {'name', 'description'},
  'person': {'name', 'bio'},
};
