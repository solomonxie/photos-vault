import 'security_scoped_bookmark.dart';

enum LocalFolderAccessOutcome { ok, cannotOpen }

class LocalFolderAccessCheckResult {
  const LocalFolderAccessCheckResult(this.outcome, {this.bookmarkData});

  final LocalFolderAccessOutcome outcome;
  final String? bookmarkData;

  bool get isOk => outcome == LocalFolderAccessOutcome.ok;
}

/// Verifies the picked folder can actually be opened via a security-scoped
/// bookmark before it's persisted — same "validate first" shape as
/// `checkBucketAccess` for S3 targets.
Future<LocalFolderAccessCheckResult> checkFolderAccess({
  required String path,
  SecurityScopedBookmarkResolver resolver = const PlatformSecurityScopedBookmarkResolver(),
}) async {
  try {
    final bookmarkData = await resolver.createBookmark(path);
    final resolvedPath = await resolver.resolveAndStartAccess(bookmarkData);
    if (resolvedPath == null) {
      return const LocalFolderAccessCheckResult(LocalFolderAccessOutcome.cannotOpen);
    }
    await resolver.stopAccess(resolvedPath);
    return LocalFolderAccessCheckResult(LocalFolderAccessOutcome.ok, bookmarkData: bookmarkData);
  } catch (_) {
    return const LocalFolderAccessCheckResult(LocalFolderAccessOutcome.cannotOpen);
  }
}
