import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/sync/merge.dart';
import 'package:photos_vault/sync/op.dart';
import 'package:photos_vault/sync/segment.dart';

/// A segment the browser engine wrote (extension/src/sync/segment.ts),
/// read here: the two codecs must agree byte for byte on what an op says.
void main() {
  test('a browser segment reads back op for op', () {
    final s = Segment.decode(
      File('docs/design/cloud-sync/vectors/wire/browser-000000000007.ndjson.gz')
          .readAsBytesSync(),
      lastModified: 1793414100000,
    );
    expect((s.d, s.seq), ('browser', 7));
    expect(s.vv, {'phone': 3});
    expect(
      [for (final o in s.ops) (o.e, o.id, o.o, o.f)],
      [
        ('asset', 'A/L0/001', OpKind.set, 'description'),
        ('asset', 'A/L0/001', OpKind.madd, 'tags'),
        ('album', 'L', OpKind.mrem, 'members'),
        ('album', 'N', OpKind.add, null),
      ],
    );
    expect(s.ops.first.x, 'Beach, day 2 — 海滩');
    expect(s.ops[2].ts, ['1793414000000-0000@phone']);
    expect((s.ops[3].x as Map)['cover_local_id'], isNull);
    final state = SyncState()..vv['browser'] = 6;
    expect(state.applySegment(s), isTrue);
    expect(state.entities['album/N']!.fields['name']!.x, 'New');
    expect(state.entities['asset/A/L0/001']!.members('tags'), ['sea']);
  });
}
