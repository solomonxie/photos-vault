import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';
import 'smart_collection_screen.dart';

/// Collections' "People" row: named [Person] profiles (T7.1-T7.3), each with
/// a photo count, plus a link down to the older AI people-*count* grouping
/// for finding more faces to name. See IMPLEMENTATION_PLAN.md Phase 7.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({
    super.key,
    required this.personStore,
    required this.assetRecordStore,
    this.aiAnalysisStore,
  });

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;
  final AiAnalysisStore? aiAnalysisStore;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  List<Person> _people = const [];
  Map<String, int> _counts = const {};
  String _query = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final people = await widget.personStore.listAll();
    final counts = <String, int>{};
    for (final person in people) {
      counts[person.id] = (await widget.personStore.localIdsIn(person.id))
          .length;
    }
    if (!mounted) return;
    setState(() {
      _people = people;
      _counts = counts;
    });
  }

  Future<void> _addPerson() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoAlertDialog(
          title: Text(l10n.peopleNamePromptTitle),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(
              controller: controller,
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.actionCancel),
            ),
            CupertinoDialogAction(
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(controller.text.trim()),
              child: Text(l10n.actionAdd),
            ),
          ],
        ),
      ),
    );
    if (name == null || name.isEmpty) return;
    await widget.personStore.create(name: name);
    await _reload();
  }

  void _openPerson(Person person) {
    Navigator.of(context)
        .push(
          CupertinoPageRoute(
            builder: (_) => PersonPageScreen(
              person: person,
              personStore: widget.personStore,
              assetRecordStore: widget.assetRecordStore,
            ),
          ),
        )
        .then((_) => _reload());
  }

  void _openAiAnalysis() {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => SmartCollectionScreen(
          kind: SmartCollectionKind.people,
          assetRecordStore: widget.assetRecordStore,
          aiAnalysisStore: widget.aiAnalysisStore,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _people
        : _people.where((p) => p.name.toLowerCase().contains(query)).toList();
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.peopleScreenTitle),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _addPerson,
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            if (_people.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: CupertinoSearchTextField(
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            if (_people.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 48),
                child: Center(
                  child: Text(
                    l10n.peopleEmpty,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                ),
              )
            else if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 48),
                child: Center(
                  child: Text(
                    l10n.peopleSearchEmpty,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                ),
              )
            else
              for (final person in filtered)
                CupertinoListTile(
                  key: ValueKey(person.id),
                  leading: PersonAvatar(
                    assetRecordStore: widget.assetRecordStore,
                    localId: person.avatarLocalId,
                    size: 44,
                  ),
                  title: Text(person.name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${_counts[person.id] ?? 0}',
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        CupertinoIcons.chevron_forward,
                        size: 18,
                        color: CupertinoColors.systemGrey2,
                      ),
                    ],
                  ),
                  onTap: () => _openPerson(person),
                ),
            const SizedBox(height: 16),
            CupertinoListTile(
              leading: const Icon(
                CupertinoIcons.sparkles,
                color: CupertinoColors.systemIndigo,
              ),
              title: Text(l10n.peopleAiAnalysisRow),
              trailing: const Icon(
                CupertinoIcons.chevron_forward,
                size: 18,
                color: CupertinoColors.systemGrey2,
              ),
              onTap: _openAiAnalysis,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
