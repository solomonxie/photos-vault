import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/ai_vision_service.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_group_screen.dart';

enum SmartCollectionKind { people, events }

/// People/Events smart collections: analyzes each not-yet-analyzed photo via
/// [AiVisionService] (opt-in, spends the user's OpenAI credit), caches the
/// result in [AiAnalysisStore], then groups by people-count or event label.
/// Only `manualFile`-sourced assets are analyzable — `photoManager` ones need
/// T2.1's on-demand file resolution first. See IMPLEMENTATION_PLAN.md T4.4.
class SmartCollectionScreen extends StatefulWidget {
  const SmartCollectionScreen({
    super.key,
    required this.kind,
    required this.assetRecordStore,
    this.aiAnalysisStore,
    this.aiVisionService,
  });

  final SmartCollectionKind kind;
  final AssetRecordStore assetRecordStore;
  final AiAnalysisStore? aiAnalysisStore;
  final AiVisionService? aiVisionService;

  @override
  State<SmartCollectionScreen> createState() => _SmartCollectionScreenState();
}

class _SmartCollectionScreenState extends State<SmartCollectionScreen> {
  late final AiAnalysisStore _aiAnalysisStore = widget.aiAnalysisStore ?? AiAnalysisStore();
  late final AiVisionService _aiVisionService = widget.aiVisionService ?? AiVisionService();

  List<AssetRecord> _analyzable = const [];
  Map<String, AiPhotoAnalysis> _analyses = {};
  bool _analyzing = false;
  int _done = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await widget.assetRecordStore.listAll();
    final analyses = await _aiAnalysisStore.listAll();
    if (!mounted) return;
    setState(() {
      _analyzable = all
          .where((r) => !r.isDeleted && !r.isHidden && r.sourceType == AssetSourceType.manualFile && r.sourcePath != null)
          .toList();
      _analyses = analyses;
    });
  }

  List<AssetRecord> get _unanalyzed => _analyzable.where((r) => !_analyses.containsKey(r.localId)).toList();

  Future<void> _analyze() async {
    final pending = _unanalyzed;
    setState(() {
      _analyzing = true;
      _done = 0;
      _error = null;
    });
    for (final record in pending) {
      try {
        final result = await _aiVisionService.analyze(localId: record.localId, imageFile: File(record.sourcePath!));
        await _aiAnalysisStore.save(result);
        if (!mounted) return;
        setState(() {
          _analyses = {..._analyses, record.localId: result};
          _done++;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _error = e.toString());
        break;
      }
    }
    if (mounted) setState(() => _analyzing = false);
  }

  String _peopleGroupKey(AppLocalizations l10n, int count) {
    if (count <= 0) return l10n.smartCollectionsNoPeople;
    if (count == 1) return l10n.smartCollectionsOnePerson;
    return l10n.smartCollectionsPeopleCount(count);
  }

  Map<String, List<AssetRecord>> _groups(AppLocalizations l10n) {
    final groups = <String, List<AssetRecord>>{};
    for (final record in _analyzable) {
      final analysis = _analyses[record.localId];
      if (analysis == null) continue;
      final key = widget.kind == SmartCollectionKind.people
          ? _peopleGroupKey(l10n, analysis.peopleCount)
          : (analysis.eventLabel.isEmpty ? l10n.smartCollectionsUncategorized : analysis.eventLabel);
      groups.putIfAbsent(key, () => []).add(record);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = widget.kind == SmartCollectionKind.people ? l10n.collectionsPeopleRow : l10n.collectionsEventsRow;
    final pendingCount = _unanalyzed.length;
    final groups = _groups(l10n);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(title)),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: CupertinoColors.systemRed)),
              const SizedBox(height: 12),
            ],
            if (pendingCount > 0)
              CupertinoButton.filled(
                onPressed: _analyzing ? null : _analyze,
                child: Text(
                  _analyzing
                      ? l10n.smartCollectionsAnalyzing(_done, pendingCount)
                      : l10n.smartCollectionsAnalyzeButton(pendingCount),
                ),
              ),
            if (groups.isEmpty && pendingCount == 0)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Center(
                  child: Text(l10n.smartCollectionsEmpty, style: const TextStyle(color: CupertinoColors.systemGrey)),
                ),
              ),
            for (final entry in groups.entries)
              CupertinoListTile(
                title: Text(entry.key),
                trailing: Text('${entry.value.length}', style: const TextStyle(color: CupertinoColors.systemGrey)),
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (_) =>
                        AssetGroupScreen(title: entry.key, records: entry.value, assetRecordStore: widget.assetRecordStore),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
