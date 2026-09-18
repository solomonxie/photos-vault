import 'package:photos_vault/photos/ai_analysis.dart';
import 'package:photos_vault/photos/suggestion_review.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';

AiPhotoAnalysis _suggestion(String localId) => AiPhotoAnalysis(
  localId: localId,
  peopleCount: 0,
  eventLabel: 'Beach day',
  analyzedAt: DateTime.now(),
  tags: const ['beach'],
  description: 'A day at the beach.',
);

void main() {
  late FakeAssetRecordStore records;
  late FakeAiAnalysisStore analyses;

  setUp(() {
    records = FakeAssetRecordStore();
    analyses = FakeAiAnalysisStore();
  });

  test('keeping a suggestion puts it on the photo and stops asking', () async {
    await records.upsert(localId: 'photo:a', contentHash: 'a', platform: 'ios');
    await records.setTags('photo:a', ['holiday']);
    await analyses.saveSuggestion(_suggestion('photo:a'));

    await acceptSuggestion(
      _suggestion('photo:a'),
      records: records,
      analyses: analyses,
    );

    final after = (await records.getByLocalId('photo:a'))!;
    expect(
      after.tags,
      containsAll(['holiday', 'beach']),
      reason: 'accepting adds to the work already done, it never replaces it',
    );
    expect(after.description, 'A day at the beach.');
    expect(after.event, 'Beach day');
    expect(await analyses.unreviewed(), isEmpty);
  });

  test('a caption already written is not overwritten', () async {
    await records.upsert(localId: 'photo:a', contentHash: 'a', platform: 'ios');
    await records.setDescription('photo:a', 'Mum on the pier');
    await records.setEvent('photo:a', 'Summer 2019');

    await acceptSuggestion(
      _suggestion('photo:a'),
      records: records,
      analyses: analyses,
    );

    final after = (await records.getByLocalId('photo:a'))!;
    expect(after.description, 'Mum on the pier');
    expect(after.event, 'Summer 2019');
    expect(after.tags, ['beach'], reason: 'tags still merge');
  });

  test('turning one down leaves the photo alone', () async {
    await records.upsert(localId: 'photo:a', contentHash: 'a', platform: 'ios');
    await analyses.saveSuggestion(_suggestion('photo:a'));

    await dismissSuggestion('photo:a', analyses: analyses);

    final after = (await records.getByLocalId('photo:a'))!;
    expect(after.tags, isEmpty);
    expect(after.description, isEmpty);
    expect(
      await analyses.unreviewed(),
      isEmpty,
      reason: 'answered, so it is never offered — or paid for — again',
    );
  });
}
