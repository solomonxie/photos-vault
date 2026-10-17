import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/ai_analysis_store.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/unnamed_faces.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AssetRecord _record(String id, int day, {bool hidden = false}) => AssetRecord(
  localId: id,
  contentHash: id,
  platform: 'test',
  createdAt: DateTime.utc(2026, 1, day),
  updatedAt: DateTime.utc(2026, 1, day),
  isHidden: hidden,
);

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late AiAnalysisStore store;
  const face = FaceRect(0.3, 0.3, 0.2, 0.2);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('unnamed_faces_');
    store = AiAnalysisStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'ai_analysis.db'),
    );
    forgetUnnamedFacesMemo();
  });
  tearDown(() async {
    await store.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> faceIn(String id, List<double> v, {String? personId}) async {
    await store.saveFaceCount(
      localId: id,
      peopleCount: 1,
      analyzedAt: DateTime.utc(2026),
      faces: const [face],
    );
    await store.saveDescriptor(
      localId: id,
      face: face,
      personId: personId,
      descriptor: FaceDescriptor(
        vector: Float32List.fromList(v),
        revision: FaceDescriptor.combineRevision(1, 4),
      ),
    );
  }

  Future<UnnamedFaces> find(
    List<AssetRecord> records, {
    Set<String> tagged = const {},
    int scanLimit = 1200,
  }) => findUnnamedFaces(
    analysisStore: store,
    records: records,
    taggedLocalIds: tagged,
    scanLimit: scanLimit,
  );

  test('folds faces that look alike into one circle, biggest first', () async {
    await faceIn('a', [1, 0, 0]);
    await faceIn('b', [1, 0.05, 0]);
    await faceIn('c', [0, 1, 0]);
    final records = [_record('a', 1), _record('b', 2), _record('c', 3)];

    final found = await find(records);

    expect(found.found, 3);
    expect(found.faces.map((f) => (f.localId, f.alike)), [('b', 2), ('c', 1)]);
  });

  test('a face past the window is counted, not folded', () async {
    await faceIn('old', [1, 0, 0]);
    await faceIn('new', [1, 0, 0]);
    final records = [_record('old', 1), _record('new', 2)];

    final found = await find(records, scanLimit: 1);

    expect(found.found, 2);
    expect(found.faces.single.localId, 'new');
    expect(found.faces.single.alike, 1);
  });

  test('tagged and hidden photos are left out', () async {
    await faceIn('a', [1, 0, 0]);
    await faceIn('b', [0, 1, 0]);
    await faceIn('c', [0, 0, 1]);
    final records = [
      _record('a', 1),
      _record('b', 2, hidden: true),
      _record('c', 3),
    ];

    final found = await find(records, tagged: {'c'});

    expect(found.faces.map((f) => f.localId), ['a']);
  });

  test('a named face does not fold the strangers', () async {
    await faceIn('a', [1, 0, 0]);
    await faceIn('named', [1, 0, 0], personId: 'nina');
    final records = [_record('a', 1), _record('named', 2)];

    final found = await find(records);

    expect(found.faces.map((f) => (f.localId, f.alike)), [
      ('named', 1),
      ('a', 1),
    ]);
  });

  test('more faces than the isolate threshold fold the same way', () async {
    final records = <AssetRecord>[];
    for (var i = 0; i < 200; i++) {
      await faceIn('p$i', i.isEven ? [1, 0, 0] : [0, 1, 0]);
      records.add(_record('p$i', 1 + i % 28));
    }

    final found = await find(records);

    expect(found.found, 200);
    expect(found.faces.map((f) => f.alike), [100, 100]);
  });

  test('an unchanged face set is not read again', () async {
    await faceIn('a', [1, 0, 0]);
    final faceless = _record('faceless', 2);
    final first = await find([_record('a', 1), faceless]);

    // Hiding a photo with no faces moves nothing the row depends on.
    final again = await find([
      _record('a', 1),
      _record('faceless', 2, hidden: true),
    ]);

    expect(identical(again.faces, first.faces), isTrue);
  });

  test('a write to the faces is read again', () async {
    await faceIn('a', [1, 0, 0]);
    final first = await find([_record('a', 1), _record('b', 2)]);

    await faceIn('b', [1, 0, 0]);
    final again = await find([_record('a', 1), _record('b', 2)]);

    expect(identical(again.faces, first.faces), isFalse);
    expect(again.faces.single.alike, 2);
  });

  test('naming a photo is read again', () async {
    await faceIn('a', [1, 0, 0]);
    await faceIn('b', [0, 1, 0]);
    final records = [_record('a', 1), _record('b', 2)];
    await find(records);

    final again = await find(records, tagged: {'b'});

    expect(again.faces.map((f) => f.localId), ['a']);
  });
}
