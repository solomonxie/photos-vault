import 'dart:io';

import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../photos/words_file.dart';
import '../photos/words_store.dart';
import '../photos/work_history_file.dart';
import 'person_import_screen.dart';
import 'words_screen.dart';

/// Words from the Mac: a `.zip` of `words.jsonl` and `media/`.
Future<PersonImportPlan> readWordsPlan(
  String path,
  AppLocalizations l10n, {
  required PersonStore personStore,
  WordsStore? store,
}) async {
  final export = await readWordsFile(path);
  if (export.writings.isEmpty) throw NothingToImport(l10n.wordsNothing);
  final counts = export.counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final number = NumberFormat.decimalPattern();
  final dated = [for (final w in export.writings) ?w.at]..sort();
  return PersonImportPlan(
    rows: [
      (l10n.wordsAll, number.format(export.writings.length)),
      for (final MapEntry(:key, :value) in counts)
        (writingKindLabel(l10n, key), number.format(value)),
      if (dated.isNotEmpty)
        (
          l10n.wordsSpan,
          '${DateFormat.yMMM().format(dated.first)} – ${DateFormat.yMMM().format(dated.last)}',
        ),
      (l10n.wordsMedia, number.format(export.mediaFiles)),
    ],
    run: (personId, onProgress) async {
      final words = store ?? WordsStore();
      final total = export.writings.length;
      if (export.mediaFiles > 0) {
        final root = await wordsMediaRoot();
        await Directory(root).create(recursive: true);
        await extractWordsMedia(path, root);
      }
      onProgress(0.5);
      await words.insert(
        personId,
        export.writings,
        onProgress: (done) => onProgress(0.5 + done / total / 2),
      );
      await personStore.logImports({
        personId: {'source': 'words', 'count': total},
      });
      return l10n.wordsImported(total);
    },
  );
}

/// Jobs from the Mac, for the profile's Job section.
Future<PersonImportPlan> readWorkHistoryPlan(
  String path,
  AppLocalizations l10n,
  PersonStore store,
) async {
  final file = WorkHistoryFile.parse(await File(path).readAsString());
  if (file.jobs.isEmpty) throw NothingToImport(l10n.workHistoryNothing);
  final (lo, hi) = file.span;
  return PersonImportPlan(
    rows: [
      for (final job in file.jobs)
        (
          job.title,
          [
            job.startDate == null
                ? '?'
                : DateFormat.yMMM().format(job.startDate!),
            job.endDate == null
                ? l10n.personHistoryPresentLabel
                : DateFormat.yMMM().format(job.endDate!),
          ].join(' – '),
        ),
      if (lo != null && hi != null)
        (
          l10n.wordsSpan,
          '${DateFormat.y().format(lo)} – ${DateFormat.y().format(hi)}',
        ),
      (l10n.workHistoryRoles, '${file.titles}'),
      (l10n.workHistoryProjects, '${file.projects}'),
    ],
    run: (personId, onProgress) async {
      final (added, replaced) = await importWorkHistory(
        store,
        personId,
        file,
        scope: PersonScope.open,
      );
      await store.logImports({
        personId: {'source': 'jobs', 'added': added, 'replaced': replaced},
      });
      onProgress(1);
      return l10n.workHistoryImported(added, replaced);
    },
  );
}
