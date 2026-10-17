import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// The full-size files photo_manager leaves in tmp for an upload or a
/// check: `AssetEntity.file`'s JPEG renders
/// (`tmp/flutter-images/<sha>_exif.jpg`, a fresh one per call, BG-2) and the
/// PhotoKit resources `originFile` and `getBaseFile` write
/// (`tmp/.image/<id>_<date>_o_<name>`, cached by id and modification date).
/// The plugin never removes either.
///
/// Whoever uses one [hold]s it; the upload releases its own with
/// `delete: true` once the transfer is over, and [sweep] takes what the
/// rest left behind.
class TempRenders {
  TempRenders._();

  static const dirName = 'flutter-images';

  /// photo_manager's `PM_IMAGE_CACHE_PATH`. `.video` is left alone:
  /// playback and video uploads read it.
  static const resourceDirName = '.image';

  static final _holds = <String, int>{};
  static final _dirs = <String>{};

  static bool isRender(String path) {
    final dir = p.basename(p.dirname(path));
    return dir == resourceDirName ||
        (dir == dirName && path.endsWith('_exif.jpg'));
  }

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

  /// Deletes files older than [olderThan] that nobody holds, in an
  /// isolate. The age covers users that don't [hold] (a hide's copy, a
  /// share) and a transfer in another engine. [inTransfer] names the files
  /// background transfers still read (a put left running by a killed app);
  /// when it can't say (null), nothing is swept. Returns how many went.
  static Future<int> sweep({
    Duration olderThan = const Duration(hours: 1),
    String? tempDir,
    Future<Set<String>?> Function()? inTransfer,
  }) async {
    final base = tempDir ?? Directory.systemTemp.path;
    final dirs = {
      ..._dirs,
      p.join(base, dirName),
      p.join(base, resourceDirName),
    };
    final Set<String> busy;
    try {
      final named = inTransfer == null ? const <String>{} : await inTransfer();
      if (named == null) return 0;
      busy = {..._holds.keys, ...named};
    } catch (_) {
      return 0;
    }
    final cutoff = DateTime.now().subtract(olderThan);
    try {
      return await Isolate.run(() {
        // Resolved: `/var` and `/private/var` are one file to iOS.
        String real(String path) {
          try {
            return File(path).resolveSymbolicLinksSync();
          } catch (_) {
            return p.normalize(path);
          }
        }

        final kept = {for (final path in busy) real(path)};
        var gone = 0;
        for (final dir in dirs) {
          final d = Directory(dir);
          if (!d.existsSync()) continue;
          for (final entry in d.listSync()) {
            if (entry is! File || !isRender(entry.path)) continue;
            if (kept.contains(real(entry.path))) continue;
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
