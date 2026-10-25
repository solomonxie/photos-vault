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

  final _paths = <String, String>{};
  final _waiters = <String, Set<VoidCallback>>{};

  /// Newest last; may hold stale entries, skipped unless still [_queued].
  final _waiting = <AssetRecord>[];
  final _queued = <String>{};
  final _started = <String>{};
  var _running = 0;

  String? pathOf(String localId) => _paths[localId];

  /// [onLanded] runs when [record]'s thumbnail arrives, until [cancel].
  void request(AssetRecord record, VoidCallback onLanded) {
    final id = record.localId;
    if (_paths.containsKey(id)) return;
    (_waiters[id] ??= {}).add(onLanded);
    if (_started.contains(id)) return;
    _queued.add(id);
    _waiting.add(record);
    _pump();
  }

  /// A tile that left the screen: its fetch is dropped unless under way.
  void cancel(String localId, VoidCallback onLanded) {
    final waiters = _waiters[localId];
    if (waiters == null || !waiters.remove(onLanded) || waiters.isNotEmpty) {
      return;
    }
    _waiters.remove(localId);
    _queued.remove(localId);
  }

  /// A thumbnail made elsewhere (Suggestions), for tiles already showing
  /// their placeholder.
  void landed(String localId, String path) {
    _started.add(localId);
    _queued.remove(localId);
    _land(localId, path);
  }

  void _land(String localId, String path) {
    _paths[localId] = path;
    final waiters = _waiters.remove(localId);
    if (waiters == null) return;
    for (final notify in waiters) {
      notify();
    }
  }

  void _pump() {
    while (_running < concurrency && _waiting.isNotEmpty) {
      final record = _waiting.removeLast();
      if (!_queued.remove(record.localId)) continue;
      _started.add(record.localId);
      _running++;
      unawaited(_one(record));
    }
    // Only stale entries left: drop them rather than hold every record
    // scrolled past.
    if (_queued.isEmpty) _waiting.clear();
  }

  Future<void> _one(AssetRecord record) async {
    try {
      final path = await fetch(record);
      if (path != null) _land(record.localId, path);
    } catch (_) {
      // Offline or no such object: the placeholder stays.
    } finally {
      _running--;
      _pump();
    }
  }
}
