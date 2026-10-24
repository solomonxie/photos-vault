import 'dart:convert';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/merge_suggestions.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';

/// Flagged Items → Merge People: each pair of likely-one people, with
/// which to keep. Nothing merges without a confirm.
class MergePeopleScreen extends StatefulWidget {
  const MergePeopleScreen({
    super.key,
    required this.suggestions,
    required this.personStore,
    required this.assetRecordStore,
    this.aiAnalysisStore,
  });

  final List<MergeSuggestion> suggestions;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;
  final AiAnalysisStore? aiAnalysisStore;

  @override
  State<MergePeopleScreen> createState() => _MergePeopleScreenState();
}

class _MergePeopleScreenState extends State<MergePeopleScreen> {
  late List<MergeSuggestion> _left = [...widget.suggestions];
  Map<String, List<String>> _members = const {};
  Map<String, AssetRecord> _records = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final members = await widget.personStore.allMemberships();
    final firsts = {
      for (final s in _left)
        for (final p in [s.a, s.b])
          ?(p.avatarLocalId ?? members[p.id]?.firstOrNull),
    };
    final records = await widget.assetRecordStore.listOf(firsts);
    if (!mounted) return;
    setState(() {
      _members = members;
      _records = {for (final r in records) r.localId: r};
    });
  }

  Future<void> _merge(MergeSuggestion s, Person keep, Person gone) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final merged = await mergePeopleInto(
        context,
        keep: keep,
        gone: [gone],
        personStore: widget.personStore,
        assetRecordStore: widget.assetRecordStore,
        aiAnalysisStore: widget.aiAnalysisStore,
      );
      if (!merged || !mounted) return;
      setState(
        () => _left = [
          for (final other in _left)
            if (other.a.id != gone.id && other.b.id != gone.id) other,
        ],
      );
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dismiss(MergeSuggestion s) async {
    setState(() => _left = [..._left]..remove(s));
    final store = widget.assetRecordStore;
    var dismissed = <String>[];
    try {
      final raw = await store.getAppState(MergeSuggestion.dismissedKey);
      if (raw != null) dismissed = (jsonDecode(raw) as List).cast<String>();
    } catch (_) {}
    dismissed.add(s.key);
    // The last 500: an old "not the same" is not worth the space forever.
    if (dismissed.length > 500) {
      dismissed = dismissed.sublist(dismissed.length - 500);
    }
    try {
      await store.setAppState(
        MergeSuggestion.dismissedKey,
        jsonEncode(dismissed),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.mergePeopleTitle),
      ),
      child: SafeArea(
        child: _left.isEmpty
            ? Center(
                child: Text(l10n.mergePeopleEmpty, style: settingsHintStyle),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(settingsPagePadding),
                itemCount: _left.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _card(l10n, _left[i]),
              ),
      ),
    );
  }

  Widget _card(AppLocalizations l10n, MergeSuggestion s) {
    Widget side(Person keep, Person gone) {
      final count = _members[keep.id]?.length ?? 0;
      return Expanded(
        child: Column(
          children: [
            PersonAvatar.forPerson(
              assetRecordStore: widget.assetRecordStore,
              person: keep,
              firstTaggedLocalId: _members[keep.id]?.firstOrNull,
              records: _records,
              size: 56,
            ),
            const SizedBox(height: 6),
            Text(
              keep.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: settingsRowTitleStyle,
            ),
            Text(l10n.mergePeoplePhotos(count), style: settingsHintStyle),
            CupertinoButton(
              key: ValueKey('mergeKeep-${keep.id}'),
              padding: const EdgeInsets.symmetric(vertical: 6),
              onPressed: _busy ? null : () => _merge(s, keep, gone),
              child: Text(
                l10n.mergePeopleKeep,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      key: ValueKey('mergeSuggestion-${s.key}'),
      decoration: BoxDecoration(
        color: settingsControlFill,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    s.sameName
                        ? l10n.mergePeopleSameName
                        : l10n.mergePeopleSimilar,
                    style: settingsHintStyle,
                  ),
                ),
              ),
              CupertinoButton(
                key: ValueKey('mergeDismiss-${s.key}'),
                padding: EdgeInsets.zero,
                minimumSize: const Size(32, 32),
                onPressed: _busy ? null : () => _dismiss(s),
                child: Text(
                  l10n.mergePeopleNotSame,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [side(s.a, s.b), side(s.b, s.a)],
          ),
        ],
      ),
    );
  }
}

/// Folds each of [gone] into [keep] after one confirm. Their hidden
/// folders stay under their old ids, now [keep]'s aliases, and join
/// [keep]'s own the first time [keep]'s is opened with those digits. False when
/// nothing merged: refused, cancelled, or a sealed conflict on the first.
Future<bool> mergePeopleInto(
  BuildContext context, {
  required Person keep,
  required List<Person> gone,
  required PersonStore personStore,
  required AssetRecordStore assetRecordStore,
  AiAnalysisStore? aiAnalysisStore,
}) async {
  final l10n = AppLocalizations.of(context)!;
  Future<void> note(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialog).pop(),
          child: Text(l10n.actionOk),
        ),
      ],
    ),
  );
  if (gone.isEmpty) return false;
  if (keep.locked || gone.any((p) => p.locked)) {
    await note(l10n.mergePeopleLocked);
    return false;
  }
  if (!context.mounted) return false;
  final names = gone.map((p) => p.name).join(', ');
  final ok = await showCupertinoDialog<bool>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      title: Text(l10n.mergePeopleConfirmTitle(names, keep.name)),
      content: Text(l10n.mergePeopleConfirmBody(names)),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(l10n.actionCancel),
        ),
        CupertinoDialogAction(
          key: const ValueKey('mergePeopleConfirm'),
          isDestructiveAction: true,
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(l10n.mergePeopleMerge),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  var merged = 0;
  for (final person in gone) {
    final outcome = await personStore.merge(keep.id, person.id);
    if (outcome == PersonMergeOutcome.sealedConflict) {
      if (context.mounted) await note(l10n.mergePeopleSealed);
      break;
    }
    if (outcome != PersonMergeOutcome.merged) continue;
    await aiAnalysisStore?.movePerson(person.id, keep.id);
    merged++;
  }
  return merged > 0;
}
