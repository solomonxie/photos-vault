import '../storage/asset_record_store.dart';
import 'conversation_store.dart';
import 'person_store.dart';
import 'words_store.dart';

const importLogBackfillKey = 'people.importLogBackfilled';

/// Once per install: "imported" change-log lines for what came in before
/// imports were logged — messages, writings and jobs already in the
/// stores, dated now. A person with a line for that source is skipped.
/// Profile files left nothing to tell them apart by, so they get none.
/// Returns how many lines were written.
Future<int> backfillImportLog({
  required PersonStore people,
  required AssetRecordStore settings,
  ConversationStore? chats,
  WordsStore? words,
}) async {
  if (await settings.getAppState(importLogBackfillKey) == '1') return 0;
  final known = {for (final p in await people.listAll()) p.id};
  final logged = await people.importedSources();
  bool wants(String id, String source) =>
      known.contains(id) && !(logged[id]?.contains(source) ?? false);

  Future<T> orEmpty<T>(Future<T> Function() read, T empty) async {
    try {
      return await read();
    } catch (_) {
      return empty;
    }
  }

  final bySource = await orEmpty(
    (chats ?? ConversationStore()).countsBySource,
    const <String, Map<String, int>>{},
  );
  final writings = await orEmpty(
    (words ?? WordsStore()).countsByPerson,
    const <String, int>{},
  );
  final jobs = await people.importedJobCounts();

  final lines = [
    {
      for (final MapEntry(:key, :value) in bySource.entries)
        if (wants(key, 'chats'))
          key: {
            'source': 'chats',
            'count': value.values.fold(0, (a, b) => a + b),
            'sources': value.keys.toList()..sort(),
          },
    },
    {
      for (final MapEntry(:key, :value) in writings.entries)
        if (wants(key, 'words')) key: {'source': 'words', 'count': value},
    },
    {
      for (final MapEntry(:key, :value) in jobs.entries)
        if (wants(key, 'jobs'))
          key: {'source': 'jobs', 'added': value, 'replaced': 0},
    },
  ];
  for (final batch in lines) {
    await people.logImports(batch);
  }
  await settings.setAppState(importLogBackfillKey, '1');
  return lines.fold<int>(0, (n, b) => n + b.length);
}
