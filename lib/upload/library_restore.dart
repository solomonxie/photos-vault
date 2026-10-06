import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'original_restore.dart';

/// How far through a refill we are, for the line on screen.
class RestoreProgress {
  const RestoreProgress({
    required this.done,
    required this.total,
    required this.failed,
  });

  final int done;
  final int total;
  final int failed;

  bool get isFinished => done + failed >= total;
}

/// Puts a library back on a phone that hasn't got one.
///
/// The app-data snapshot restores every record — the dates, the albums, the
/// people, the captions — but a record is not a picture. Thumbnails live in
/// the app container and the container is deleted with the app, so after a
/// reinstall the grid is the right shape and entirely blank, and the only
/// way back was to open each photo and tap Download: thirty thousand taps.
///
/// **Thumbnails first, and thumbnails only.** They are a few kilobytes
/// each, so the whole library becomes visible on a phone connection in
/// minutes, and the grid is what people mean by "my photos are back". The
/// full-resolution copy stays in the bucket until something actually wants
/// it — opening a photo, or exporting one — because pulling thirty thousand
/// originals down is gigabytes of somebody's data plan to reproduce what
/// they deliberately moved off the device.
class LibraryRestore {
  LibraryRestore({required this.recordStore, required this.originals});

  final AssetRecordStore recordStore;
  final OriginalRestore originals;

  /// Small-file fetches, so a handful at a time rather than one after
  /// another — and a handful rather than all of them, because thirty
  /// thousand simultaneous requests is a self-inflicted rate limit.
  static const concurrency = 6;

  /// Which records would be fetched. Separate from [run] so a screen can
  /// say how many before asking, and say nothing when the answer is none.
  Future<List<AssetRecord>> owed({Set<String>? only}) async => [
    for (final record in await recordStore.listAll())
      if ((only == null || only.contains(record.localId)) &&
          record.thumbnailPath == null &&
          !record.isDeleted &&
          record.passcodeHash == null &&
          record.stateOf(DerivativeKind.thumbnail).destinationKey != null)
        record,
  ];

  /// Fetches every missing thumbnail, newest first.
  ///
  /// Newest first because that is where the grid opens, so the part of the
  /// library being looked at fills while the rest arrives behind it.
  /// [onProgress] fires after each batch, not each file: a `setState` per
  /// thumbnail is thirty thousand rebuilds of a grid.
  Future<RestoreProgress> run({
    void Function(RestoreProgress progress)? onProgress,
    Set<String>? only,
  }) async {
    final records = await owed(only: only)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final total = records.length;
    var done = 0;
    var failed = 0;
    for (var i = 0; i < total; i += concurrency) {
      final batch = records.skip(i).take(concurrency);
      final results = await Future.wait(
        batch.map((record) => originals.restoreThumbnail(record)),
      );
      for (final path in results) {
        if (path == null) {
          failed++;
        } else {
          done++;
        }
      }
      onProgress?.call(
        RestoreProgress(done: done, total: total, failed: failed),
      );
    }
    return RestoreProgress(done: done, total: total, failed: failed);
  }
}
