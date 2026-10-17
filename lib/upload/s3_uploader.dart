import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../demo/demo_bucket.dart';
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
    // Demo mode's bucket exists only in the app; an upload to it lands.
    if (DemoBucket.owns(target)) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      return true;
    }
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

/// The files of every upload the native queue still holds (enqueued,
/// running or waiting to retry), in any group: what a tmp cleanup must
/// leave alone. Null when the queue can't be read.
Future<Set<String>?> activeUploadPaths({FileDownloader? downloader}) async {
  try {
    return {
      for (final task in await (downloader ?? FileDownloader()).allTasks(
        allGroups: true,
      ))
        if (task is UploadTask) await task.filePath(),
    };
  } catch (_) {
    return null;
  }
}

/// Gets one object to a file through a `background_downloader` task — a
/// video can be gigabytes, which must neither sit in memory nor stop when
/// the app is backgrounded.
class S3Downloader {
  S3Downloader({FileDownloader? downloader})
    : _downloader = downloader ?? FileDownloader();

  final FileDownloader _downloader;

  Future<bool> get({
    required String key,
    required S3BackupTarget target,
    required String toPath,
  }) async => (await fetch(target, key, toPath)).saved;

  /// [get], saying what the bucket answered: [FetchResult.status] 404 is
  /// the one answer meaning "not there".
  Future<FetchResult> fetch(
    S3BackupTarget target,
    String key,
    String toPath,
  ) async {
    try {
      final url = await presignGetUrl(target: target, key: key);
      final task = DownloadTask(
        url: url.toString(),
        filename: p.basename(toPath),
        directory: p.dirname(toPath),
        baseDirectory: BaseDirectory.root,
      );
      final result = await _downloader.download(task);
      return switch (result.status) {
        TaskStatus.complete => (saved: true, status: 200),
        TaskStatus.notFound => (saved: false, status: 404),
        _ => (saved: false, status: result.responseStatusCode),
      };
    } catch (_) {
      return (saved: false, status: null);
    }
  }
}

/// One object to a file: saved, and what the bucket said (null when
/// nothing answered).
typedef FetchResult = ({bool saved, int? status});

typedef FetchToFile = Future<FetchResult> Function(
  S3BackupTarget target,
  String key,
  String toPath,
);

/// The transfer as a test's `get` fake answers it. Never the production
/// path: bodies there stay on [S3Downloader].
FetchToFile fetchThroughGet(Future<http.Response> Function(Uri url) get) =>
    (target, key, toPath) async {
      try {
        final response = await get(
          await presignGetUrl(target: target, key: key),
        );
        if (response.statusCode != 200) {
          return (saved: false, status: response.statusCode);
        }
        await File(toPath).writeAsBytes(response.bodyBytes, flush: true);
        return (saved: true, status: 200);
      } catch (_) {
        return (saved: false, status: null);
      }
    };

/// A private file for one download, under the app's temp directory.
Future<File> downloadScratchFile(String name) async {
  final dir = await Directory.systemTemp.createTemp('pv_dl_');
  return File(p.join(dir.path, p.basename(name)));
}

/// Removes a [downloadScratchFile] and its directory.
Future<void> dropScratch(File file) async {
  try {
    await file.parent.delete(recursive: true);
  } catch (_) {}
}
