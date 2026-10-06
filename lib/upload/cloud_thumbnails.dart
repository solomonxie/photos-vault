import 'dart:async';

import 'package:flutter/foundation.dart';

import '../storage/asset_record.dart';

/// Fetches the bucket's `thumbnails/` copy for cloud-only tiles that have
/// no picture on disk — asked for by the tile as it scrolls into view, so
/// the grid fills itself instead of waiting for each photo to be opened.
///
/// Newest request first: the tiles on screen now matter more than the ones
/// scrolled past. A few at a time, each photo asked about once a session.
class CloudThumbnails {
  CloudThumbnails({required this.fetch, this.concurrency = 4});

  /// Set by the library once its stores exist; null in tests, where a tile
  /// just keeps its placeholder.
  static CloudThumbnails? instance;

  /// Returns the cached file's path, or null when the bucket has none.
  final Future<String?> Function(AssetRecord record) fetch;
  final int concurrency;

  /// localId → fetched path. A new map on every landing, so a listening
  /// tile rebuilds.
  final ValueNotifier<Map<String, String>> fetched = ValueNotifier(const {});

  final _asked = <String>{};
  final _waiting = <AssetRecord>[];
  var _running = 0;

  void request(AssetRecord record) {
    if (!_asked.add(record.localId)) return;
    _waiting.add(record);
    _pump();
  }

  void _pump() {
    while (_running < concurrency && _waiting.isNotEmpty) {
      final record = _waiting.removeLast();
      _running++;
      unawaited(_one(record));
    }
  }

  Future<void> _one(AssetRecord record) async {
    try {
      final path = await fetch(record);
      if (path != null) {
        fetched.value = {...fetched.value, record.localId: path};
      }
    } catch (_) {
      // Offline or no such object: the placeholder stays.
    } finally {
      _running--;
      _pump();
    }
  }
}
