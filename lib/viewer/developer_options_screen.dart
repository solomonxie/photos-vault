import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/conversation_store.dart';
import '../photos/face_analyzer.dart';
import '../photos/face_import.dart';
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record_store.dart';
import 'conversation_import_screen.dart';
import 'face_import_screen.dart';
import 'life_imports.dart';
import 'person_import_screen.dart';
import 'people_zip_screen.dart';
import 'profile_transfer_screen.dart';

/// Imports from files made outside the app, each with how it works and the
/// file it reads, folded until asked for.
class DeveloperOptionsScreen extends StatelessWidget {
  const DeveloperOptionsScreen({
    super.key,
    required this.personStore,
    required this.assetRecordStore,
    required this.analysisStore,
    this.conversationStore,
  });

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;
  final AiAnalysisStore analysisStore;
  final ConversationStore? conversationStore;

  static const _csvExample =
      'name,birthdate,groups,jobs\n'
      'Ava Chen,1990-04,Uni|school;Book club,Designer|Studio A|2015|2019';

  static const _zipExample =
      'people.csv\n'
      'photos/Ava Chen/IMG_0001.jpg\n'
      'photos/Ava Chen/beach.heic';

  static const _facesExample =
      '{"version": 2,\n'
      ' "groups": [\n'
      '   {"id": "r1-0001", "faces": 120, "suggest": "Ava Chen"},\n'
      '   {"id": "r1-0002", "faces": 8}],\n'
      ' "photos": [\n'
      '   {"key": "2024_05_01_IMG_0001",\n'
      '    "faces": [\n'
      '      {"box": [0.41, 0.22, 0.16, 0.21], "person": "Ava Chen"},\n'
      '      {"box": [0.62, 0.30, 0.10, 0.14], "group": "r1-0002"}]}]}';

  static const _chatsExample =
      '{"person": "Ava Chen", "at": "2021-03-04T18:22:05",\n'
      ' "from_me": false, "text": "See you at 7",\n'
      ' "chat": "wechat:ava", "source": "wechat",\n'
      ' "kind": "text", "sender": "Ava"}';

  static const _wordsExample =
      '{"id": "weibo-2012-0412-a1", "kind": "post",\n'
      ' "title": "", "at": "2012-04-12T21:30:00",\n'
      ' "source": "weibo", "origin": "Blog/2012年微博汇总.md",\n'
      ' "text": "春天来了\\n\\n![](media/weibo-2012-0412-a1/1.jpg)"}';

  static const _jobsExample =
      '{"version": 1, "jobs": [\n'
      ' {"employer": "Studio A", "start": "2015-03", "end": "2019-06",\n'
      '  "fields": [{"label": "City", "value": "Beijing"}],\n'
      '  "titles": [{"title": "Designer", "start": "2015-03"}],\n'
      '  "projects": [{"name": "Brand refresh", "tags": ["design"]}]}]}';

  Future<void> _open(BuildContext context, Widget screen) =>
      Navigator.of(context)
          .push(CupertinoPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.devTitle),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                settingsPagePadding + 16,
                12,
                settingsPagePadding + 16,
                20,
              ),
              child: Text(l10n.devIntro, style: settingsHintStyle),
            ),
            SettingsGroupHeading(title: l10n.devSectionPeople),
            _Tool(
              key: const ValueKey('devCsvImport'),
              icon: CupertinoIcons.doc_text_fill,
              color: CupertinoColors.systemGreen,
              title: l10n.devCsvImportTitle,
              format: 'CSV',
              summary: l10n.devCsvImportSummary,
              how: l10n.devCsvImportHow,
              spec: l10n.devCsvImportSpec,
              example: _csvExample,
              action: l10n.devChooseFile,
              onRun: () => _open(
                context,
                ProfileTransferScreen(
                  personStore: personStore,
                  start: ProfileTransferStart.import,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _Tool(
              key: const ValueKey('devCsvExport'),
              icon: CupertinoIcons.square_arrow_up_fill,
              color: CupertinoColors.systemGreen,
              title: l10n.devCsvExportTitle,
              format: 'CSV',
              summary: l10n.devCsvExportSummary,
              how: l10n.devCsvExportHow,
              action: l10n.devExportNow,
              onRun: () => _open(
                context,
                ProfileTransferScreen(
                  personStore: personStore,
                  start: ProfileTransferStart.export,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _Tool(
              key: const ValueKey('devZipImport'),
              icon: CupertinoIcons.archivebox_fill,
              color: CupertinoColors.systemOrange,
              title: l10n.devZipTitle,
              format: 'ZIP',
              summary: l10n.devZipSummary,
              how: l10n.devZipHow,
              spec: l10n.devZipSpec,
              example: _zipExample,
              action: l10n.devChooseFile,
              onRun: () => _open(
                context,
                PeopleZipScreen(
                  personStore: personStore,
                  assetRecordStore: assetRecordStore,
                ),
              ),
            ),
            const SizedBox(height: 28),
            SettingsGroupHeading(title: l10n.devSectionFaces),
            _Tool(
              key: const ValueKey('devFacesImport'),
              icon: CupertinoIcons.person_crop_square_fill,
              color: CupertinoColors.systemIndigo,
              title: l10n.devFacesTitle,
              format: 'JSON',
              summary: l10n.devFacesSummary,
              how: l10n.devFacesHow,
              spec: l10n.devFacesSpec,
              example: _facesExample,
              action: l10n.devChooseFile,
              onRun: () => _open(
                context,
                FaceImportScreen(
                  import: FaceImport(
                    personStore: personStore,
                    assetRecordStore: assetRecordStore,
                    analysisStore: analysisStore,
                    analyzer: FaceAnalyzer.shared,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            SettingsGroupHeading(title: l10n.devSectionChats),
            _Tool(
              key: const ValueKey('devChatsImport'),
              icon: CupertinoIcons.chat_bubble_2_fill,
              color: CupertinoColors.systemTeal,
              title: l10n.devChatsTitle,
              format: 'JSONL',
              summary: l10n.devChatsSummary,
              how: l10n.devChatsHow,
              spec: l10n.devChatsSpec,
              example: _chatsExample,
              action: l10n.devChooseFile,
              onRun: () => _open(
                context,
                ConversationImportScreen(
                  personStore: personStore,
                  conversationStore: conversationStore,
                  pickOnOpen: true,
                ),
              ),
            ),
            const SizedBox(height: 28),
            SettingsGroupHeading(title: l10n.devSectionLife),
            _Tool(
              key: const ValueKey('devWordsImport'),
              icon: CupertinoIcons.doc_text_fill,
              color: CupertinoColors.systemOrange,
              title: l10n.devWordsTitle,
              format: 'ZIP',
              summary: l10n.devWordsSummary,
              how: l10n.devWordsHow,
              spec: l10n.devWordsSpec,
              example: _wordsExample,
              action: l10n.devChooseFile,
              onRun: () => _open(
                context,
                PersonImportScreen(
                  title: l10n.devWordsTitle,
                  hint: l10n.devWordsSummary,
                  extensions: const ['zip', 'jsonl'],
                  read: (path) => readWordsPlan(path, l10n),
                  personStore: personStore,
                  assetRecordStore: assetRecordStore,
                  pickOnOpen: true,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _Tool(
              key: const ValueKey('devJobsImport'),
              icon: CupertinoIcons.briefcase_fill,
              color: CupertinoColors.systemBrown,
              title: l10n.devJobsTitle,
              format: 'JSON',
              summary: l10n.devJobsSummary,
              how: l10n.devJobsHow,
              spec: l10n.devJobsSpec,
              example: _jobsExample,
              action: l10n.devChooseFile,
              onRun: () => _open(
                context,
                PersonImportScreen(
                  title: l10n.devJobsTitle,
                  hint: l10n.devJobsSummary,
                  extensions: const ['json'],
                  read: (path) => readWorkHistoryPlan(path, l10n, personStore),
                  personStore: personStore,
                  assetRecordStore: assetRecordStore,
                  pickOnOpen: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One import: what it is, two folds (how it works, the file it reads)
/// and the button that runs it.
class _Tool extends StatelessWidget {
  const _Tool({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.format,
    required this.summary,
    required this.how,
    this.spec,
    this.example,
    required this.action,
    required this.onRun,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String format;
  final String summary;
  final String how;
  final String? spec;
  final String? example;
  final String action;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(settingsPagePadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SettingsIconTile(icon: icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(title, style: settingsRowTitleStyle),
                        ),
                        const SizedBox(width: 8),
                        _FormatTag(format),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(summary, style: settingsRowSubtitleStyle),
                  ],
                ),
              ),
            ],
          ),
        ),
        _Fold(title: l10n.devHowItWorks, child: _Prose(how)),
        if (spec != null)
          _Fold(
            title: l10n.devFileSpec,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Prose(spec!),
                if (example != null) ...[
                  const SizedBox(height: 12),
                  Text(l10n.devExample, style: settingsSubheadingStyle),
                  const SizedBox(height: 6),
                  _Code(example!),
                ],
              ],
            ),
          ),
        SettingsGroupRow(title: action, accent: true, onTap: onRun),
      ],
    );
  }
}

class _FormatTag extends StatelessWidget {
  const _FormatTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: settingsTertiary),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: settingsSecondary,
      ),
    ),
  );
}

/// A row that opens to show [child] beneath it.
class _Fold extends StatefulWidget {
  const _Fold({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  State<_Fold> createState() => _FoldState();
}

class _FoldState extends State<_Fold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SettingsGroupRow(
        title: widget.title,
        trailing: AnimatedRotation(
          turns: _open ? 0.25 : 0,
          duration: const Duration(milliseconds: 150),
          child: const Icon(
            CupertinoIcons.chevron_forward,
            size: 14,
            color: settingsTertiary,
          ),
        ),
        onTap: () => setState(() => _open = !_open),
      ),
      if (_open)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            settingsPagePadding,
            0,
            settingsPagePadding,
            settingsPagePadding,
          ),
          child: widget.child,
        ),
    ],
  );
}

class _Prose extends StatelessWidget {
  const _Prose(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 13,
      height: 1.45,
      color: settingsSecondary,
    ),
  );
}

/// Monospace, scrolled sideways rather than wrapped: a wrapped line of a
/// file format reads as two lines.
class _Code extends StatelessWidget {
  const _Code(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: settingsPageBackground,
      borderRadius: BorderRadius.circular(8),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'Menlo',
          fontSize: 11.5,
          height: 1.4,
          color: CupertinoColors.white,
        ),
      ),
    ),
  );
}
