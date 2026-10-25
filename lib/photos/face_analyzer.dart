import 'dart:async';

import 'package:flutter/foundation.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'ai_analysis.dart';
import 'ai_analysis_store.dart';
import 'face_identity.dart';
import 'on_device_analysis.dart';

/// Looks for faces in the photos it's given — the one open, or a batch
/// picked in the grid — one at a time, out of sight. Nothing sweeps the
/// library: what's analysed is what somebody looked at or asked about.
///
/// Opening another photo adds it behind the current one; nothing already
/// started is dropped. Not persisted: a photo still to do is just one with
/// no analysis row, and opening it again asks again.
class FaceAnalyzer {
  FaceAnalyzer({
    required this.assetRecordStore,
    required this.analysisStore,
    required this.onDeviceAnalysis,
    required this.resolvePath,
    Future<String?> Function(AssetRecord record)? resolveSource,
    this.faceIdentity,
    this.taggedPeopleOf,
  }) : resolveSource = resolveSource ?? resolvePath;

  static const perPhoto = Duration(seconds: 60);

  /// The one the app runs; set by the library screen.
  static FaceAnalyzer? shared;

  final AssetRecordStore assetRecordStore;
  final AiAnalysisStore analysisStore;
  final OnDeviceAnalysisService onDeviceAnalysis;
  final Future<String?> Function(AssetRecord record) resolvePath;
  final Future<String?> Function(AssetRecord record) resolveSource;
  final FaceIdentityService? faceIdentity;

  /// Who is tagged in one photo, read fresh.
  final Future<List<String>> Function(String localId)? taggedPeopleOf;

  /// Photos with at least one face found, for the grid's face badge.
  final ValueNotifier<Set<String>> withFaces = ValueNotifier(const {});

  /// Photos queued or being looked at, for a spinner where one is open.
  final ValueNotifier<Set<String>> working = ValueNotifier(const {});

  final _finished = StreamController<String>.broadcast();

  /// Each photo's id once it has been looked at, faces or not.
  Stream<String> get finished => _finished.stream;

  final _pending = <String>{};
  Future<void>? _drain;

  /// Reads which photos already have faces. Once, at start.
  Future<void> load() async {
    try {
      withFaces.value = (await analysisStore.facesByAsset()).keys.toSet();
    } catch (_) {
      // No analysis database: no badges until something is analysed.
    }
  }

  /// Queues [localIds] behind whatever is running. Returns at once.
  void add(Iterable<String> localIds) {
    _pending.addAll(localIds);
    working.value = {...working.value, ..._pending};
    _drain ??= _run().whenComplete(() => _drain = null);
  }

  /// Done with everything queued so far. For tests.
  Future<void> get idle async {
    while (_drain != null) {
      await _drain;
    }
  }

  Future<void> _run() async {
    while (_pending.isNotEmpty && !_disposed) {
      final id = _pending.first;
      _pending.remove(id);
      try {
        // Bounded: a photo still coming down from iCloud mustn't hold up
        // the ones behind it.
        await _bounded(_analyze(id));
      } catch (_) {
        // Tried again the next time it's opened.
      }
      if (_disposed) return;
      working.value = {...working.value}..remove(id);
      if (!_finished.isClosed) _finished.add(id);
    }
  }

  Future<void> _analyze(String localId) async {
    final record = await assetRecordStore.getByLocalId(localId);
    if (record == null || record.isVideo) return;
    if (!await _findFaces(record)) return;
    final faces = await analysisStore.facesFor(localId);
    final had = withFaces.value.contains(localId);
    if (faces.isNotEmpty != had) {
      withFaces.value = faces.isEmpty
          ? ({...withFaces.value}..remove(localId))
          : {...withFaces.value, localId};
    }
    final identity = faceIdentity;
    if (identity == null || faces.isEmpty) return;
    // One face, one person: iOS won't say whose face is whose, so a
    // group shot can't teach the reference set anything certain.
    final people = await taggedPeopleOf?.call(localId) ?? const [];
    if (faces.length == 1 && people.length == 1) {
      await identity.remember(
        record: record,
        face: faces.single,
        personId: people.single,
      );
    }
  }

  Timer? _limit;
  bool _disposed = false;

  /// [work], or [perPhoto] — whichever is first. The timer is dropped on
  /// [dispose], so nothing outlives the screen that owns this.
  Future<void> _bounded(Future<void> work) {
    final done = Completer<void>();
    _limit = Timer(perPhoto, () {
      if (!done.isCompleted) done.completeError(TimeoutException(null));
    });
    work.then(
      (_) => done.isCompleted ? null : done.complete(),
      onError: (Object e) => done.isCompleted ? null : done.completeError(e),
    );
    return done.future.whenComplete(() => _limit?.cancel());
  }

  /// False when there was nothing on the phone to look at yet.
  Future<bool> _findFaces(AssetRecord record) async {
    AiPhotoAnalysis? existing;
    try {
      existing = await analysisStore.get(record.localId);
    } catch (_) {}
    final legacy = existing?.legacyBoxes ?? false;
    final emptyBefore =
        existing != null &&
        existing.peopleCount == 0 &&
        existing.analyzedAt.isBefore(OnDeviceAnalysisService.smallerFacesSince);
    if (existing != null &&
        !existing.needsLookingAt &&
        !legacy &&
        !emptyBefore) {
      return true;
    }
    // Old boxes are turned by the file's own EXIF orientation, which only
    // the file has.
    final path = legacy
        ? await resolvePath(record)
        : await resolveSource(record);
    if (path == null) return false;
    if (existing != null &&
        !existing.needsLookingAt &&
        legacy &&
        !emptyBefore) {
      return onDeviceAnalysis.settleBoxes(record, path);
    }
    return await onDeviceAnalysis.analyze(record, path) != null;
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
    _limit?.cancel();
    _finished.close();
    withFaces.dispose();
    working.dispose();
  }
}
