import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// The full-size JPEGs `AssetEntity.file` leaves in tmp.
///
/// photo_manager renders the photo again on every call, writes it to
/// `tmp/flutter-images/<sha>_exif.jpg` and never removes it (BG-2). Whoever
/// uses one [hold]s it; the upload releases its own with `delete: true`
/// once the transfer is over, and [sweep] takes what the rest left behind.
class TempRenders {
  TempRenders._();

  static const dirName = 'flutter-images';

  static final _holds = <String, int>{};
  static final _dirs = <String>{};

  static bool isRender(String path) =>
      p.basename(p.dirname(path)) == dirName && path.endsWith('_exif.jpg');

  /// In use: neither [release] nor [sweep] deletes it until let go.
  static void hold(String? path) {
    if (path == null || !isRender(path)) return;
    _dirs.add(p.dirname(path));
    _holds.update(path, (n) => n + 1, ifAbsent: () => 1);
  }

  /// Done with [path]. With [delete], removed once nobody else holds it.
  static Future<void> release(String? path, {bool delete = false}) async {
    if (path == null || !isRender(path)) return;
    final left = (_holds[path] ?? 1) - 1;
    if (left > 0) {
      _holds[path] = left;
      return;
    }
    _holds.remove(path);
    if (!delete) return;
    try {
      await File(path).delete();
    } catch (_) {
      // Already gone.
    }
  }

  static bool isHeld(String path) => _holds.containsKey(path);

  /// Deletes renders older than [olderThan] that nobody holds, in an
  /// isolate. The age covers users that don't [hold] (a hide's copy, a
  /// share) and a transfer in another engine. Returns how many went.
  static Future<int> sweep({
    Duration olderThan = const Duration(hours: 1),
    String? tempDir,
  }) async {
    final dirs = {
      ..._dirs,
      p.join(tempDir ?? Directory.systemTemp.path, dirName),
    };
    final held = _holds.keys.toSet();
    final cutoff = DateTime.now().subtract(olderThan);
    try {
      return await Isolate.run(() {
        var gone = 0;
        for (final dir in dirs) {
          final d = Directory(dir);
          if (!d.existsSync()) continue;
          for (final entry in d.listSync()) {
            if (entry is! File || !isRender(entry.path)) continue;
            if (held.contains(entry.path)) continue;
            try {
              if (entry.statSync().modified.isAfter(cutoff)) continue;
              entry.deleteSync();
              gone++;
            } catch (_) {
              // Gone already, or in use; the next sweep tries again.
            }
          }
        }
        return gone;
      });
    } catch (_) {
      return 0;
    }
  }

  /// Tests only.
  static void reset() {
    _holds.clear();
    _dirs.clear();
  }
}
