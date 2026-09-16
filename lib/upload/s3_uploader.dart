import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;

import '../settings/s3_backup_target.dart';
import 'signing.dart';

/// Puts one derivative file to one [S3BackupTarget] via a presigned URL,
/// through a `background_downloader` upload task so it survives
/// backgrounding. Single-part only — T3.3 handles large files via multipart.
class S3Uploader {
  S3Uploader({FileDownloader? downloader})
    : _downloader = downloader ?? FileDownloader();

  final FileDownloader _downloader;

  Future<bool> put({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) async {
    try {
      final url = await presignPutUrl(target: target, key: key);
      final task = UploadTask(
        url: url.toString(),
        filename: p.basename(filePath),
        directory: p.dirname(filePath),
        baseDirectory: BaseDirectory.root,
        httpRequestMethod: 'PUT',
        post: 'binary',
      );
      final result = await _downloader.upload(task);
      return result.status == TaskStatus.complete;
    } catch (_) {
      return false;
    }
  }
}
