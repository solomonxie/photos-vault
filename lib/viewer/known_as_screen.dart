import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/known_names.dart';
import '../photos/person_store.dart';
import 'profile_section.dart';

/// The names and chats imports matched to someone; swipe one away and the
/// next import asks about it again.
class KnownAsScreen extends StatefulWidget {
  const KnownAsScreen({
    super.key,
    required this.personId,
    required this.personStore,
  });

  final String personId;
  final PersonStore personStore;

  @override
  State<KnownAsScreen> createState() => _KnownAsScreenState();
}

class _KnownAsScreenState extends State<KnownAsScreen> {
  List<KnownAs> _known = const [];

  @override
  void initState() {
    super.initState();
    widget.personStore.knownAsOf(widget.personId).then((known) {
      if (mounted) setState(() => _known = known);
    });
  }

  Future<void> _forget(KnownAs known) async {
    setState(() => _known = [..._known]..remove(known));
    await widget.personStore.forgetKnownAs(known);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.knownAsHeader)),
      child: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                l10n.knownAsHint,
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.systemGrey,
                ),
              ),
            ),
            if (_known.isNotEmpty)
              ProfileCard(
                children: [
                  for (final k in _known)
                    ProfileDeletableRow(
                      key: ValueKey('knownAs:${k.kind}:${k.key}'),
                      editing: false,
                      onDelete: () => _forget(k),
                      child: CupertinoListTile(
                        leading: Icon(
                          k.kind == KnownAs.handle
                              ? CupertinoIcons.chat_bubble_2
                              : CupertinoIcons.person,
                          size: 18,
                          color: CupertinoColors.systemGrey,
                        ),
                        title: Text(k.value),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
