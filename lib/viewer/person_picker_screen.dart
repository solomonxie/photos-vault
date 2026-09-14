import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';

/// Searchable person picker for Relationships' "+" (T7.5) — search [candidates]
/// by name, or "New Person…" to create one on the spot (no photo required).
/// Pops with the chosen/created [Person], or `null` if backed out.
class PersonPickerScreen extends StatefulWidget {
  const PersonPickerScreen({super.key, required this.candidates, required this.personStore});

  final List<Person> candidates;
  final PersonStore personStore;

  @override
  State<PersonPickerScreen> createState() => _PersonPickerScreenState();
}

class _PersonPickerScreenState extends State<PersonPickerScreen> {
  final _controller = TextEditingController();
  String _query = '';

  Future<void> _createNew() async {
    final l10n = AppLocalizations.of(context)!;
    final nameController = TextEditingController(text: _query);
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoAlertDialog(
          title: Text(l10n.peopleNamePromptTitle),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(controller: nameController, autofocus: true, onChanged: (_) => setState(() {})),
          ),
          actions: [
            CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.actionCancel)),
            CupertinoDialogAction(
              onPressed: nameController.text.trim().isEmpty ? null : () => Navigator.of(context).pop(nameController.text.trim()),
              child: Text(l10n.actionAdd),
            ),
          ],
        ),
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final created = await widget.personStore.create(name: name);
    if (mounted) Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? widget.candidates
        : widget.candidates.where((p) => p.name.toLowerCase().contains(query)).toList();

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.relationshipPickerTitle)),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: CupertinoSearchTextField(
                controller: _controller,
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  CupertinoListTile(
                    leading: const Icon(CupertinoIcons.add_circled),
                    title: Text(l10n.personProfileNewPersonOption),
                    onTap: _createNew,
                  ),
                  for (final person in matches)
                    CupertinoListTile(title: Text(person.name), onTap: () => Navigator.of(context).pop(person)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
