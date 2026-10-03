import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../settings/s3_listing.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';

class ImportResult {
  const ImportResult({
    required this.imported,
    required this.unreachable,
    required this.skippedAppOwned,
  });

  final int imported;
  final bool unreachable;

  /// Unreferenced `photo_*` objects: this app's own naming, so either a
  /// hidden carrier (never shown as a plain photo) or a lost record.
  final int skippedAppOwned;
}

/// Adds photos and videos dropped straight into a bucket by something other
/// than this app (`scripts/import-to-bucket.sh`) to the library, cloud-only:
/// the grid shows the thumbnail, the original comes down when opened.
///
/// Anything this app named itself (`photo_*`) is left alone — those are its
/// own backups or hidden carriers, and a carrier's decoy must never surface
/// as an ordinary photo.
class BucketImport {
  BucketImport({required this.targetsStore, required this.recordStore});

  final BackupTargetsStore targetsStore;
  final AssetRecordStore recordStore;

  static const _videoExtensions = {'mp4', 'mov', 'm4v'};
  static const _stillExtensions = {
    'jpg',
    'jpeg',
    'png',
    'heic',
    'heif',
    'webp',
    'gif',
  };

  Future<ImportResult> run() async {
    final known = <String>{
      for (final r in await recordStore.listAll())
        for (final kind in [DerivativeKind.original, DerivativeKind.livePhoto])
          ?r.stateOf(kind).destinationKey,
    };
    var imported = 0;
    var skipped = 0;
    var unreachable = false;
    final seenNames = <String>{};
    for (final target in await targetsStore.loadAll()) {
      final originals = await _listAll(target, 'originals/');
      final thumbnails = await _listAll(target, 'thumbnails/');
      if (originals == null || thumbnails == null) {
        unreachable = true;
        continue;
      }
      final thumbByStem = {for (final o in thumbnails) _stem(o.key): o.key};
      for (final object in originals) {
        final name = object.key.split('/').last;
        final ext = name.contains('.')
            ? name.split('.').last.toLowerCase()
            : '';
        final isVideo = _videoExtensions.contains(ext);
        if (!isVideo && !_stillExtensions.contains(ext)) continue;
        if (known.contains(object.key)) continue;
        if (name.startsWith('photo_')) {
          skipped++;
          continue;
        }
        if (!seenNames.add(name)) continue;
        await _add(
          object: object,
          name: name,
          isVideo: isVideo,
          thumbnailKey: thumbByStem[_stem(object.key)],
        );
        imported++;
      }
    }
    return ImportResult(
      imported: imported,
      unreachable: unreachable,
      skippedAppOwned: skipped,
    );
  }

  Future<void> _add({
    required S3Object object,
    required String name,
    required bool isVideo,
    required String? thumbnailKey,
  }) async {
    final localId = 'bucket:$name';
    final created = takenAt(name) ?? object.lastModified.toLocal();
    await recordStore.upsert(
      localId: localId,
      contentHash: localId,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      isVideo: isVideo,
      createdAt: created,
    );
    await recordStore.updateDerivative(
      localId,
      DerivativeKind.original,
      DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: object.key,
      ),
    );
    if (thumbnailKey != null) {
      await recordStore.updateDerivative(
        localId,
        DerivativeKind.thumbnail,
        DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: thumbnailKey,
        ),
      );
    }
    await recordStore.setLocalDeleted(localId, true);
  }

  /// `import_20251228120340_x.mp4` → 2025-12-28 12:03:40. The first 14-digit
  /// run in the name, which is what camera and dashcam exports put there.
  static DateTime? takenAt(String name) {
    final m = RegExp(r'(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})')
        .firstMatch(name);
    if (m == null) return null;
    final p = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
    if (p[1] < 1 || p[1] > 12 || p[2] < 1 || p[2] > 31 || p[3] > 23) {
      return null;
    }
    return DateTime(p[0], p[1], p[2], p[3], p[4], p[5]);
  }

  static String _stem(String key) {
    final name = key.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  Future<List<S3Object>?> _listAll(S3BackupTarget target, String dir) async {
    final out = <S3Object>[];
    String? token;
    do {
      final result = await listBucket(
        target: target,
        prefix: '${target.prefix}$dir',
        continuationToken: token,
      );
      final page = result.page;
      if (!result.isOk || page == null) return null;
      out.addAll(page.objects);
      token = page.nextToken;
    } while (token != null);
    return out;
  }
}
