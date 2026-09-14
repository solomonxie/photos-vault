import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

/// Searchable "select if it exists, type to create if it doesn't" picker —
/// shared by Education/Job (T7.3) and relationship organizations
/// (company/school/org, T7.5). Pops with the chosen or freshly-typed value,
/// or `null` if the user backs out without picking anything.
class StringPickerScreen extends StatefulWidget {
  const StringPickerScreen({super.key, required this.title, required this.options, this.initialQuery = ''});

  final String title;
  final Set<String> options;
  final String initialQuery;

  @override
  State<StringPickerScreen> createState() => _StringPickerScreenState();
}

class _StringPickerScreenState extends State<StringPickerScreen> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialQuery);
  late String _query = widget.initialQuery;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = _query.trim();
    final matches = widget.options.where((o) => o.toLowerCase().contains(query.toLowerCase())).toList()..sort();
    final exactMatch = matches.any((o) => o.toLowerCase() == query.toLowerCase());

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.title)),
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
                  if (query.isNotEmpty && !exactMatch)
                    CupertinoListTile(
                      leading: const Icon(CupertinoIcons.add_circled),
                      title: Text(l10n.stringPickerUseValue(query)),
                      onTap: () => Navigator.of(context).pop(query),
                    ),
                  for (final option in matches)
                    CupertinoListTile(title: Text(option), onTap: () => Navigator.of(context).pop(option)),
                  if (matches.isEmpty && query.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                      child: Text(l10n.stringPickerTypeToCreate, style: const TextStyle(color: CupertinoColors.systemGrey)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
