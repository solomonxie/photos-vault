import 'dart:convert';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';

/// Photos whose original is gone from every bucket with no copy left on this
/// phone: nothing can re-upload them. Their original is marked `failed`, so
/// the grid draws the red line, and the id is kept here so the Safety page
/// says "lost" instead of "requeued".
class LostOriginals {
  LostOriginals(this.store);

  final AssetRecordStore store;

  static const _key = 'lost_original_ids';

  Future<Set<String>> _read() async {
    final raw = await store.getAppState(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as List).cast<String>().toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> add(String localId) async {
    final ids = await _read();
    if (ids.add(localId)) {
      await store.setAppState(_key, jsonEncode(ids.toList()));
    }
  }

  /// The ids still lost: a record that was re-uploaded, binned or removed
  /// drops out.
  Future<Set<String>> current() async {
    final ids = await _read();
    if (ids.isEmpty) return ids;
    final alive = <String>{};
    for (final record in await store.listAll()) {
      if (ids.contains(record.localId) &&
          !record.isDeleted &&
          record.stateOf(DerivativeKind.original).status !=
              UploadStatus.uploaded) {
        alive.add(record.localId);
      }
    }
    if (alive.length != ids.length) {
      await store.setAppState(_key, jsonEncode(alive.toList()));
    }
    return alive;
  }
}

/// Photos to prove against the bucket first on the next sync — what an
/// OS-side delete leaves behind: the photo was called cloud-only on the
/// strength of its row, and the row has not been asked yet.
class ProofQueue {
  ProofQueue(this.store);

  final AssetRecordStore store;

  static const _key = 'spot_check_priority';

  Future<List<String>> _read() async {
    final raw = await store.getAppState(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  Future<void> add(String localId) async {
    final ids = await _read();
    if (ids.contains(localId)) return;
    await store.setAppState(_key, jsonEncode([...ids, localId]));
  }

  Future<List<String>> take(int limit) async {
    final ids = await _read();
    if (ids.isEmpty) return const [];
    final taken = ids.take(limit).toList();
    await store.setAppState(_key, jsonEncode(ids.skip(limit).toList()));
    return taken;
  }
}
