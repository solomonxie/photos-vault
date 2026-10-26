import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';

/// Everyone a group links somebody to, searchable, built as it scrolls —
/// a company of a thousand is one row on the profile and this list behind
/// it.
class ProfilePeopleListScreen extends StatefulWidget {
  const ProfilePeopleListScreen({
    super.key,
    required this.title,
    required this.people,
    required this.personStore,
    required this.assetRecordStore,
  });

  final String title;

  /// Closest first; shown in this order.
  final List<Person> people;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  @override
  State<ProfilePeopleListScreen> createState() =>
      _ProfilePeopleListScreenState();
}

class _ProfilePeopleListScreenState extends State<ProfilePeopleListScreen> {
  final _search = TextEditingController();
  late List<Person> _shown = widget.people;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _filter(String text) {
    final q = text.trim().toLowerCase();
    setState(
      () => _shown = q.isEmpty
          ? widget.people
          : [
              for (final p in widget.people)
                if (p.name.toLowerCase().contains(q)) p,
            ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.title)),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: CupertinoSearchTextField(
                key: const ValueKey('profilePeopleSearch'),
                controller: _search,
                placeholder: l10n.profileRelationshipsSearch(
                  widget.people.length,
                ),
                onChanged: _filter,
              ),
            ),
            Expanded(
              child: _shown.isEmpty
                  ? Center(
                      child: Text(
                        l10n.peopleSearchEmpty,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _shown.length,
                      itemExtent: 56,
                      itemBuilder: (context, i) {
                        final p = _shown[i];
                        return CupertinoListTile(
                          key: ValueKey('profilePeople:${p.id}'),
                          leading: PersonAvatar.forPerson(
                            assetRecordStore: widget.assetRecordStore,
                            person: p,
                            size: 36,
                          ),
                          leadingSize: 36,
                          title: Text(p.name),
                          trailing: const Icon(
                            CupertinoIcons.chevron_forward,
                            size: 18,
                            color: CupertinoColors.systemGrey2,
                          ),
                          onTap: () => Navigator.of(context).push(
                            CupertinoPageRoute<void>(
                              builder: (_) => PersonPageScreen(
                                person: p,
                                personStore: widget.personStore,
                                assetRecordStore: widget.assetRecordStore,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
