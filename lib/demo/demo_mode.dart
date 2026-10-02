import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'demo_flag.dart';
import 'demo_seed.dart';

/// Demo mode: a second, pre-filled library beside the real one.
///
/// Separate by construction rather than by care. Every file root the app
/// asks for (Application Support, Documents, Caches, tmp) and the sqlite
/// folder get a `demo/` subfolder; keychain keys get a `demo.` prefix
/// (`FlutterSecureStore`); the photo library and iCloud Drive answer as
/// empty and unavailable (`PhotoLibraryService`, `ICloudDrive`). Nothing
/// the stores do changes — they just open somewhere else.
class DemoMode {
  static const namespace = 'demo';
  static const _marker = 'demo_mode_on';

  /// Which library the screens show. The app rebuilds them from scratch
  /// when it flips, so every store is constructed again against the other
  /// root.
  static final ValueNotifier<bool> shown = ValueNotifier(false);

  /// Bumped by [reset], so a library already showing the demo is rebuilt
  /// against the fresh seed.
  static final ValueNotifier<int> resets = ValueNotifier(0);

  static PathProviderPlatform? _realPaths;
  static String? _realDatabases;

  /// Before `runApp`. Installs the redirects and restores the last choice.
  static Future<void> init() async {
    final current = PathProviderPlatform.instance;
    if (current is! _DemoPaths) {
      _realPaths = current;
      PathProviderPlatform.instance = _DemoPaths(current);
    }
    try {
      _realDatabases = await sqflite.databaseFactory.getDatabasesPath();
    } catch (_) {
      // No sqlite plugin (tests); nothing to redirect.
    }
    final on = await (await _markerFile())?.exists() == true;
    await _apply(on);
    if (on) await DemoSeed().ensure();
    shown.value = on;
  }

  /// Switches the whole app; seeds the demo library on the way in.
  static Future<void> setActive(bool on) async {
    final marker = await _markerFile();
    if (marker != null) {
      if (on) {
        await marker.writeAsString('1');
      } else if (await marker.exists()) {
        await marker.delete();
      }
    }
    await _apply(on);
    if (on) await DemoSeed().ensure();
    shown.value = on;
  }

  /// Wipes the demo store — databases, files, `demo.` keychain keys — and
  /// seeds it again if it's showing. The real store is never touched.
  static Future<void> reset() async {
    final databases = _realDatabases;
    if (databases != null) {
      final dir = Directory(p.join(databases, namespace));
      if (await dir.exists()) {
        await for (final file in dir.list()) {
          // Closes any open handle before the file goes.
          if (file is File &&
              !file.path.contains(RegExp(r'-(wal|shm|journal)$'))) {
            await sqflite.databaseFactory.deleteDatabase(file.path);
          }
        }
      }
    }
    final real = _realPaths;
    if (real != null) {
      for (final root in [
        real.getTemporaryPath,
        real.getApplicationSupportPath,
        real.getLibraryPath,
        real.getApplicationDocumentsPath,
        real.getApplicationCachePath,
      ]) {
        try {
          final base = await root();
          if (base == null) continue;
          final dir = Directory(p.join(base, namespace));
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
    try {
      const storage = FlutterSecureStorage();
      for (final key in (await storage.readAll()).keys) {
        if (key.startsWith('$namespace.')) await storage.delete(key: key);
      }
    } catch (_) {
      // No keychain (tests).
    }
    if (!DemoFlag.active) return;
    await _apply(true);
    await DemoSeed().ensure();
    resets.value++;
  }

  static Future<void> _apply(bool on) async {
    DemoFlag.active = on;
    final real = _realDatabases;
    if (real == null) return;
    final path = on ? p.join(real, namespace) : real;
    await Directory(path).create(recursive: true);
    await sqflite.databaseFactory.setDatabasesPath(path);
  }

  /// In the real Application Support folder, outside the demo one, so it
  /// can be read before either is chosen.
  static Future<File?> _markerFile() async {
    final dir = await _realPaths?.getApplicationSupportPath();
    return dir == null ? null : File(p.join(dir, _marker));
  }
}

class _DemoPaths extends PathProviderPlatform {
  _DemoPaths(this._real);

  final PathProviderPlatform _real;

  Future<String?> _scoped(Future<String?> path) async {
    final base = await path;
    if (base == null || !DemoFlag.active) return base;
    final dir = Directory(p.join(base, DemoMode.namespace));
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getTemporaryPath() => _scoped(_real.getTemporaryPath());

  @override
  Future<String?> getApplicationSupportPath() =>
      _scoped(_real.getApplicationSupportPath());

  @override
  Future<String?> getLibraryPath() => _scoped(_real.getLibraryPath());

  @override
  Future<String?> getApplicationDocumentsPath() =>
      _scoped(_real.getApplicationDocumentsPath());

  @override
  Future<String?> getApplicationCachePath() =>
      _scoped(_real.getApplicationCachePath());

  @override
  Future<String?> getExternalStoragePath() =>
      _scoped(_real.getExternalStoragePath());

  @override
  Future<List<String>?> getExternalCachePaths() =>
      _real.getExternalCachePaths();

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      _real.getExternalStoragePaths(type: type);

  @override
  Future<String?> getDownloadsPath() => _real.getDownloadsPath();
}
