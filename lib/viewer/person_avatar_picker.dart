import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid_view.dart';

/// Pick which of a person's own photos is their profile picture.
///
/// Their photos and nobody else's: a profile picture that isn't of them is
/// the one thing this can get wrong, and the library picker would make it
/// the easiest thing to do. Pops with the chosen `localId`, or null.
class PersonAvatarPicker extends StatefulWidget {
  const PersonAvatarPicker({
    super.key,
    required this.person,
    required this.personStore,
    required this.assetRecordStore,
  });

  final Person person;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  @override
  State<PersonAvatarPicker> createState() => _PersonAvatarPickerState();
}

class _PersonAvatarPickerState extends State<PersonAvatarPicker> {
  List<AssetRecord> _records = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ids = (await widget.personStore.localIdsIn(widget.person.id)).toSet();
    final all = await widget.assetRecordStore.listAll();
    if (!mounted) return;
    setState(() {
      _records =
          all.where((r) => ids.contains(r.localId) && !r.isDeleted).toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.personProfileAvatarPickerTitle),
      ),
      child: SafeArea(
        child: !_loaded
            ? const Center(child: CupertinoActivityIndicator())
            : _records.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    l10n.personProfileAvatarPickerEmpty,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                ),
              )
            : AssetGridView(
                records: _records,
                onTap: (record) => Navigator.of(context).pop(record.localId),
                actionsFor: (r) => const [],
              ),
      ),
    );
  }
}
