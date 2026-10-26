import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/face_identity.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/storage/asset_record.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';

void main() {
  late FakeAssetRecordStore records;
  late FakeAiAnalysisStore analyses;
  late FaceIdentityService identity;

  const face = FaceRect(0.3, 0.3, 0.4, 0.4);

  setUp(() {
    records = FakeAssetRecordStore();
    analyses = FakeAiAnalysisStore();
    identity = FaceIdentityService(analysisStore: analyses);
  });

  Future<AssetRecord> photo(String id) =>
      records.upsert(localId: id, contentHash: id, platform: 'ios');

  test('naming links each face', () async {
    final a = await photo('a');
    final b = await photo('b');

    final saved = await identity.rememberMany([
      (record: a, face: face),
      (record: b, face: face),
    ], 'nina');

    expect(saved, isTrue);
    expect(await analyses.faceOfPersonIn('a', 'nina'), face);
    expect(await analyses.faceOfPersonIn('b', 'nina'), face);
  });

  test('taking back one face leaves the others', () async {
    await identity.remember(
      record: await photo('a'),
      face: face,
      personId: 'nina',
    );
    await identity.remember(
      record: await photo('b'),
      face: face,
      personId: 'nina',
    );

    await identity.unremember(localId: 'b', face: face);

    expect((await analyses.facesOfPerson('nina')).map((f) => f.localId), ['a']);
  });

  test('forgetting a person takes their faces with them', () async {
    await identity.remember(
      record: await photo('a'),
      face: face,
      personId: 'nina',
    );

    await identity.forget('nina');

    expect(await analyses.facesOfPerson('nina'), isEmpty);
  });
}
