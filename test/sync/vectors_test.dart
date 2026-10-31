import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/sync/checkpoint.dart';
import 'package:photos_vault/sync/hlc.dart';
import 'package:photos_vault/sync/merge.dart';
import 'package:photos_vault/sync/op.dart';
import 'package:photos_vault/sync/segment.dart';

Segment _segment(Map<String, Object?> j) {
  final d = j['d'] as String;
  final seq = j['seq'] as int;
  final vv = (j['vv'] as Map).cast<String, int>();
  return Segment(
    d: d,
    seq: seq,
    vv: vv,
    lastModified: j['lastModified'] as int,
    ops: [
      for (final o in j['ops'] as List)
        Op.fromJson(o as Map<String, Object?>, d: d, seq: seq, vv: vv),
    ],
  );
}

/// Every order that keeps each device's own segments in seq order.
Iterable<List<Segment>> _interleavings(
  Map<String, List<Segment>> byDevice,
) sync* {
  if (byDevice.values.every((l) => l.isEmpty)) {
    yield [];
    return;
  }
  for (final d in byDevice.keys.where((d) => byDevice[d]!.isNotEmpty)) {
    final rest = {
      for (final e in byDevice.entries)
        e.key: e.key == d ? e.value.sublist(1) : e.value,
    };
    for (final tail in _interleavings(rest)) {
      yield [byDevice[d]!.first, ...tail];
    }
  }
}

Map<String, Object?> _view(SyncState s) => {
  'entities': {
    for (final ent in s.listed)
      '${ent.e}/${ent.id}': {
        'fields': {for (final f in ent.fields.entries) f.key: f.value.x},
        'sets': {
          for (final set in ent.sets.keys)
            if (ent.members(set).isNotEmpty) set: ent.members(set),
        },
      },
  },
  'conflicts': [
    for (final c in s.conflicts())
      {'e': c.e, 'id': c.id, 'f': c.f, 'x': c.x, 'd': c.d},
  ],
};

void main() {
  final dir = Directory('docs/design/cloud-sync/vectors');
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('fixtures exist', () => expect(files, isNotEmpty));

  for (final file in files) {
    final v = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final segments = [
      for (final s in v['segments'] as List)
        _segment(s as Map<String, Object?>),
    ];
    final expected = jsonDecode(jsonEncode(v['expect']));

    test(v['name'] as String, () {
      final byDevice = <String, List<Segment>>{};
      for (final s in segments) {
        (byDevice[s.d] ??= []).add(s);
      }
      var runs = 0;
      for (final order in _interleavings(byDevice)) {
        final once = SyncState();
        for (final s in order) {
          once.applySegment(s);
        }
        expect(
          _view(once),
          expected,
          reason: 'order ${order.map((s) => '${s.d}${s.seq}')}',
        );

        final twice = SyncState();
        for (final s in [...order, ...order.reversed]) {
          twice.applySegment(s);
          for (final op in s.ops) {
            if (op.wall <= s.lastModified + maxClockLead.inMilliseconds) {
              twice.apply(op);
            }
          }
        }
        expect(_view(twice), expected, reason: 'repeated');

        for (var cut = 0; cut <= order.length; cut++) {
          var s = SyncState();
          for (final seg in order.take(cut)) {
            s.applySegment(seg);
          }
          s = Checkpoint.decode(Checkpoint.encode(s, d: 'z', h: Hlc.zero));
          for (final seg in order.skip(cut)) {
            s.applySegment(seg);
          }
          expect(_view(s), expected, reason: 'checkpoint after $cut');
        }

        final wire = order.map(
          (s) => Segment.decode(s.encode(), lastModified: s.lastModified),
        );
        final decoded = SyncState();
        for (final s in wire) {
          decoded.applySegment(s);
        }
        expect(_view(decoded), expected, reason: 'segment codec');
        runs++;
      }
      expect(runs, greaterThan(0));
    });
  }
}
