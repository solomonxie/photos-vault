import 'dart:convert';
import 'dart:io' show gzip;

import 'hlc.dart';
import 'merge.dart';
import 'op.dart';
import 'segment.dart';

/// The whole merge state as one file: `sync/checkpoints/<d>/<hlc>.ndjson.gz`.
/// Loading it and applying later segments equals applying every segment.
class Checkpoint {
  static String key(String d, Hlc h) => 'sync/checkpoints/$d/$h.ndjson.gz';

  static List<int> encode(SyncState s, {required String d, required Hlc h}) =>
      gzip.encode(utf8.encode(encodeLines(s, d: d, h: h).join('\n')));

  static Iterable<String> encodeLines(
    SyncState s, {
    required String d,
    required Hlc h,
  }) sync* {
    yield header(s, d: d, h: h);
    for (final ent in s.entities.values) {
      yield entityLine(ent);
    }
  }

  static String header(SyncState s, {required String d, required Hlc h}) =>
      jsonEncode({'v': protocolVersion, 'd': d, 'h': '$h', 'vv': s.vv});

  static String entityLine(EntityState ent) => jsonEncode({
    'e': ent.e,
    'id': ent.id,
    'exists': ent.exists,
    'f': {
      for (final f in ent.fields.entries)
        f.key: {'x': f.value.x, 's': f.value.stamp},
    },
    'heads': {
      for (final hs in ent.heads.entries)
        hs.key: [
          for (final op in hs.value)
            {'x': op.x, 's': op.stamp, 'seq': op.seq, 'vv': op.vv},
        ],
    },
    'sets': {
      for (final set in ent.sets.entries)
        set.key: {
          for (final m in set.value.entries)
            m.key: {
              'a': [...m.value.adds],
              'r': [...m.value.removes],
            },
        },
    },
  });

  static SyncState decode(List<int> bytes) => decodeLines(
    const LineSplitter().convert(utf8.decode(gzip.decode(bytes))),
  );

  static SyncState decodeLines(List<String> lines) {
    final head = jsonDecode(lines.first) as Map<String, Object?>;
    final v = head['v'] as int;
    if (v > protocolVersion) throw NewerProtocol(v);
    final s = SyncState()..vv.addAll((head['vv'] as Map).cast<String, int>());
    for (final line in lines.skip(1)) {
      if (line.isNotEmpty) readEntityLine(s, line);
    }
    s.touched.clear();
    return s;
  }

  /// One [entityLine] back into [s].
  static void readEntityLine(SyncState s, String line) {
    final j = jsonDecode(line) as Map<String, Object?>;
    final ent = s.entity(j['e'] as String, j['id'] as String)
      ..exists = j['exists'] as bool;
    (j['f'] as Map).forEach((f, v) {
      final stamp = v['s'] as String;
      ent.fields[f as String] = Stamped(v['x'], stamp);
      s.seen = s.seen.receive(Hlc.parse(stamp.split('@').first));
    });
    (j['heads'] as Map).forEach((f, list) {
      ent.heads[f as String] = [
        for (final h in list as List)
          Op(
            h: (h['s'] as String).split('@').first,
            d: (h['s'] as String).split('@').last,
            seq: h['seq'] as int,
            vv: (h['vv'] as Map).cast<String, int>(),
            e: ent.e,
            id: ent.id,
            o: OpKind.set,
            f: f,
            x: h['x'],
          ),
      ];
    });
    (j['sets'] as Map).forEach((set, members) {
      final target = ent.sets.putIfAbsent(set as String, () => {});
      (members as Map).forEach((m, tags) {
        target.putIfAbsent(m as String, OrSetEntry.new)
          ..adds.addAll((tags['a'] as List).cast<String>())
          ..removes.addAll((tags['r'] as List).cast<String>());
      });
    });
  }
}
