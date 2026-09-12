import 'package:flutter/services.dart';

/// Bridges to native security-scoped bookmarks (iOS `NSURL.bookmarkData`),
/// the mechanism a sandboxed app needs to keep access to a folder the user
/// picked outside its own container, across app restarts.
abstract class SecurityScopedBookmarkResolver {
  /// Creates bookmark data for [path], a folder just returned by the picker.
  Future<String> createBookmark(String path);

  /// Resolves [bookmarkData] back to a path and starts the security scope.
  /// Returns null if the bookmark is stale — the folder moved, was renamed,
  /// deleted, or access was revoked (see T1.8: callers must prompt a
  /// re-pick, not fail silently).
  Future<String?> resolveAndStartAccess(String bookmarkData);

  /// Stops the security scope started by [resolveAndStartAccess]. Must
  /// always be called after each access, or the OS-level access grant leaks.
  Future<void> stopAccess(String path);
}

class PlatformSecurityScopedBookmarkResolver implements SecurityScopedBookmarkResolver {
  const PlatformSecurityScopedBookmarkResolver();

  static const _channel = MethodChannel('back_your_own_photos/security_scoped_bookmark');

  @override
  Future<String> createBookmark(String path) async {
    final data = await _channel.invokeMethod<String>('createBookmark', {'path': path});
    if (data == null) {
      throw StateError('Failed to create a security-scoped bookmark for $path');
    }
    return data;
  }

  @override
  Future<String?> resolveAndStartAccess(String bookmarkData) {
    return _channel.invokeMethod<String>('resolveAndStartAccess', {'bookmarkData': bookmarkData});
  }

  @override
  Future<void> stopAccess(String path) {
    return _channel.invokeMethod<void>('stopAccess', {'path': path});
  }
}
