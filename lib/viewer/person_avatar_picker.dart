import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/face_identity.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid_view.dart';
import 'person_avatar.dart';

/// Pick which of a person's own photos is their profile picture.
///
/// Their photos and nobody else's: a profile picture that isn't of them is
/// the one thing this can get wrong, and the library picker would make it
/// the easiest thing to do. Their recognised faces come first, each a
/// photo and the box to crop it to. Pops with the choice, or null.
class PersonAvatarPicker extends StatefulWidget {
  const PersonAvatarPicker({
    super.key,
    required this.person,
    required this.personStore,
    required this.assetRecordStore,
    this.aiAnalysisStore,
  });

  /// Null opens the app's own.
  final AiAnalysisStore? aiAnalysisStore;
  final Person person;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  @override
  State<PersonAvatarPicker> createState() => _PersonAvatarPickerState();
}

class _PersonAvatarPickerState extends State<PersonAvatarPicker> {
  List<AssetRecord> _records = const [];
  List<({String localId, FaceRect face})> _faces = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ids = await widget.personStore.localIdsIn(widget.person.id);
    final visible = await widget.assetRecordStore.getVisibleByLocalIds(ids);
    var faces = const <({String localId, FaceRect face})>[];
    try {
      faces = [
        for (final f
            in await (widget.aiAnalysisStore ?? AiAnalysisStore())
                .facesOfPerson(widget.person.id))
          if (visible.containsKey(f.localId)) f,
      ];
    } catch (_) {
      // No analysis database: photos only.
    }
    if (!mounted) return;
    setState(() {
      _faces = faces;
      _records = visible.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _loaded = true;
    });
  }

  /// A whole photo still crops to their face where it's known.
  Future<void> _pickPhoto(AssetRecord record) async {
    final face = await faceOfPersonIn(
      record.localId,
      widget.person.id,
      analysisStore: widget.aiAnalysisStore,
    );
    if (mounted) {
      Navigator.of(context).pop((localId: record.localId, face: face));
    }
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
            : Column(
                children: [
                  if (_faces.isNotEmpty)
                    SizedBox(
                      height: 84,
                      child: ListView(
                        key: const ValueKey('avatarPickerFaces'),
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        children: [
                          for (final f in _faces)
                            GestureDetector(
                              key: ValueKey('avatarFace-${f.localId}'),
                              onTap: () =>
                                  Navigator.of(context)
                                      .pop((localId: f.localId, face: f.face)),
                              child: Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: PersonAvatar(
                                  assetRecordStore: widget.assetRecordStore,
                                  localId: f.localId,
                                  face: f.face,
                                  size: 64,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: AssetGridView(
                      records: _records,
                      onTap: _pickPhoto,
                      actionsFor: (r) => const [],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
