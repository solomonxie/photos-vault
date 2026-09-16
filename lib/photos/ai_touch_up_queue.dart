import 'dart:io';

import 'package:flutter/foundation.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'ai_image_edit_service.dart';
import 'derived_asset.dart';
import 'person_store.dart';

/// Runs AI touch-ups in the background and files each result through
/// [createDerivedAsset] — a new library item with the source photo's
/// metadata, leaving the source itself alone.
///
/// Long-lived on purpose: the user can leave the detail screen (or the
/// photo) while a job runs, and any screen listening to [instance] shows
/// "AI working…" and refreshes when it lands.
class AiTouchUpQueue extends ChangeNotifier {
  AiTouchUpQueue({AiImageEditService? editService})
    : _editService = editService ?? AiImageEditService();

  static final AiTouchUpQueue instance = AiTouchUpQueue();

  final AiImageEditService _editService;

  final _running = <String>{};

  /// Source `localId`s with a job in flight.
  Set<String> get running => Set.unmodifiable(_running);

  bool isRunning(String localId) => _running.contains(localId);

  /// Why the last finished job failed, or `null` if it succeeded.
  String? lastError;

  /// What the last finished job created, for a "done" message.
  AssetRecord? lastCreated;

  Future<AssetRecord?> submit({
    required AssetRecord source,
    required File file,
    required String prompt,
    required AssetRecordStore store,
    PersonStore? personStore,
  }) async {
    _running.add(source.localId);
    notifyListeners();
    try {
      final edited = await _editService.edit(
        bytes: await file.readAsBytes(),
        prompt: prompt,
      );
      final created = await createDerivedAsset(
        source: source,
        bytes: edited,
        extension: '.png',
        store: store,
        personStore: personStore,
      );
      lastError = null;
      lastCreated = created;
      return created;
    } catch (e) {
      lastError = '$e';
      lastCreated = null;
      return null;
    } finally {
      _running.remove(source.localId);
      notifyListeners();
    }
  }
}
