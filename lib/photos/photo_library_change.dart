import 'package:flutter/services.dart';

/// The ids the OS photo library says changed, out of one
/// `PhotoManager.addChangeCallback` notification.
///
/// iOS's `PHPhotoLibraryChangeObserver` hands over exactly which assets were
/// inserted, altered and removed — so keeping up with Photos costs work
/// proportional to *what changed*, never to how many photos there are. A
/// hundred-thousand-photo library that gained one photo is one id.
///
/// The payload is a map of `create` / `update` / `delete` to lists of
/// `{id: <localIdentifier>}`, and is parsed defensively: it comes from a
/// platform channel, and a malformed notification should mean "fall back to
/// a scan", not a crash.
class PhotoLibraryChange {
  const PhotoLibraryChange({
    this.created = const {},
    this.updated = const {},
    this.deleted = const {},
  });

  /// Platform asset ids (not this app's `photo:`-prefixed local ids).
  final Set<String> created;
  final Set<String> updated;
  final Set<String> deleted;

  bool get isEmpty => created.isEmpty && updated.isEmpty && deleted.isEmpty;

  int get length => created.length + updated.length + deleted.length;

  static PhotoLibraryChange? parse(MethodCall call) {
    if (call.method != 'change') return null;
    final arguments = call.arguments;
    if (arguments is! Map) return null;
    return PhotoLibraryChange(
      created: _ids(arguments['create']),
      updated: _ids(arguments['update']),
      deleted: _ids(arguments['delete']),
    );
  }

  static Set<String> _ids(Object? value) {
    if (value is! List) return const {};
    return {
      for (final item in value)
        if (item is Map && item['id'] is String) item['id'] as String,
    };
  }
}
