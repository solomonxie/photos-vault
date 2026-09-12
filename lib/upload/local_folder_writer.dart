import 'dart:io';

import 'package:path/path.dart' as p;

import '../settings/backup_target.dart';
import '../settings/security_scoped_bookmark.dart';

enum LocalFolderWriteOutcome { ok, staleBookmark, ioError }

class LocalFolderWriteResult {
  const LocalFolderWriteResult(this.outcome);

  final LocalFolderWriteOutcome outcome;

  bool get isOk => outcome == LocalFolderWriteOutcome.ok;
}

/// Writes one derivative directly into a [LocalFolderBackupTarget]'s
/// bookmarked folder — no network involved. Starts/stops the security scope
/// around the single write; a bookmark that fails to resolve comes back as
/// [LocalFolderWriteOutcome.staleBookmark] so the caller can prompt a
/// re-pick (T1.8) instead of failing silently.
class LocalFolderWriter {
  LocalFolderWriter({this.resolver = const PlatformSecurityScopedBookmarkResolver()});

  final SecurityScopedBookmarkResolver resolver;

  Future<LocalFolderWriteResult> write({
    required String filePath,
    required String key,
    required LocalFolderBackupTarget target,
  }) async {
    final resolvedFolder = await resolver.resolveAndStartAccess(target.bookmarkData);
    if (resolvedFolder == null) {
      return const LocalFolderWriteResult(LocalFolderWriteOutcome.staleBookmark);
    }

    try {
      final destFile = File(p.join(resolvedFolder, key));
      await destFile.parent.create(recursive: true);
      await File(filePath).copy(destFile.path);
      return const LocalFolderWriteResult(LocalFolderWriteOutcome.ok);
    } catch (_) {
      return const LocalFolderWriteResult(LocalFolderWriteOutcome.ioError);
    } finally {
      await resolver.stopAccess(resolvedFolder);
    }
  }
}
