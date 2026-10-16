import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/cloud_thumbnails.dart';

AssetRecord _record(String id) => AssetRecord(
  localId: id,
  contentHash: id,
  platform: 'test',
  sourceType: AssetSourceType.photoManager,
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
);

void main() {
  test('a tile gone before its turn is never fetched', () async {
    final asked = <String>[];
    final gates = <String, Completer<String?>>{};
    final fetcher = CloudThumbnails(
      concurrency: 1,
      fetch: (r) {
        asked.add(r.localId);
        return (gates[r.localId] = Completer<String?>()).future;
      },
    );
    void noop() {}

    fetcher.request(_record('a'), noop);
    fetcher.request(_record('b'), noop);
    fetcher.request(_record('c'), noop);
    fetcher.cancel('b', noop);
    expect(asked, ['a']);

    gates['a']!.complete('/tmp/a.jpg');
    await Future<void>.delayed(Duration.zero);
    expect(asked, ['a', 'c'], reason: 'newest first, b dropped');
    gates['c']!.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(asked, ['a', 'c']);

    // Back on screen: asked again.
    fetcher.request(_record('b'), noop);
    expect(asked, ['a', 'c', 'b']);
  });

  test('a landing tells only the tiles showing that photo', () async {
    final gates = <String, Completer<String?>>{};
    final fetcher = CloudThumbnails(
      fetch: (r) => (gates[r.localId] = Completer<String?>()).future,
    );
    var a = 0, b = 0;
    void onA() => a++;
    void onB() => b++;

    fetcher.request(_record('a'), onA);
    fetcher.request(_record('b'), onB);
    gates['a']!.complete('/tmp/a.jpg');
    await Future<void>.delayed(Duration.zero);

    expect((a, b), (1, 0));
    expect(fetcher.pathOf('a'), '/tmp/a.jpg');
    expect(fetcher.pathOf('b'), isNull);
  });

  test('a fetch under way still lands for a tile that came back', () async {
    final gate = Completer<String?>();
    final fetcher = CloudThumbnails(fetch: (_) => gate.future);
    var calls = 0;
    void first() {}
    void second() => calls++;

    fetcher.request(_record('a'), first);
    fetcher.cancel('a', first);
    fetcher.request(_record('a'), second);
    gate.complete('/tmp/a.jpg');
    await Future<void>.delayed(Duration.zero);

    expect(calls, 1);
    expect(fetcher.pathOf('a'), '/tmp/a.jpg');
  });
}
