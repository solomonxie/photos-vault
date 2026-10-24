import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';

import 'app.dart';
import 'demo/demo_mode.dart';
import 'storage/database_home.dart';
import 'settings/app_store_region.dart';
import 'settings/secure_store.dart';
import 'upload/background_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kProfileMode) _reportJank();
  // First: demo mode reads the databases' path, and every store opens there.
  await DatabaseHome.prepare();
  // Independent platform calls, so one round trip rather than a chain.
  await Future.wait([
    _ensureTemp(),
    AppStoreRegion.load(),
    DemoMode.init(seedLater: true).catchError((_) {
      // Demo plumbing must never be why the real app doesn't open.
    }),
  ]);
  // Simulator screenshots only: /tmp/pv-screenshot ("<screen> <lang>") can't exist on a phone.
  final shot = screenshotRequest();
  if (shot != null) {
    await DemoMode.setActive(true);
    final lang = shot.$2;
    if (lang.isNotEmpty) {
      AppStoreRegion.languageChosen = true;
      AppStoreRegion.language.value = lang;
    }
  }
  runApp(const App());
  // Foreground only: background passes read whichever item exists.
  unawaited(const FlutterSecureStore().migrate().catchError((_) => false));
  unawaited(forgetRetiredAiKeys().catchError((_) {}));
}

/// Older builds could delete `tmp` itself; SQLite and every encoder need it.
Future<void> _ensureTemp() async {
  try {
    await Directory.systemTemp.create(recursive: true);
  } catch (_) {
    // Nothing better to do; the database keeps its temp data in memory.
  }
}

/// Entry point of the headless engine `ios/Runner/BackgroundSync.swift`
/// starts when iOS hands the app a processing task. Not a screen: it runs
/// one sync pass and reports back, whatever happens.
@pragma('vm:entry-point')
Future<void> backgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _ensureTemp();
  await DatabaseHome.prepare();
  const channel = MethodChannel('byo.photos/background_sync');
  final sync = BackgroundSync();
  channel.setMethodCallHandler((call) async {
    if (call.method == 'expire') sync.cancel();
  });
  var completed = false;
  try {
    completed = await sync.run();
  } catch (_) {
    // Nothing to show anyone; the work stays pending for the next run.
  } finally {
    await channel.invokeMethod<void>('done', completed);
  }
}

/// TEMPORARY — profile builds only. Which half of a slow frame is slow:
/// `build` is the UI isolate (our Dart), `raster` is the GPU thread
/// (painting, layers, saveLayer).
void _reportJank() {
  WidgetsFlutterBinding.ensureInitialized();
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final timing in timings) {
      final build = timing.buildDuration.inMicroseconds / 1000;
      final raster = timing.rasterDuration.inMicroseconds / 1000;
      final total = timing.totalSpan.inMicroseconds / 1000;
      if (total < 17) continue;
      debugPrint(
        'JANK total ${total.toStringAsFixed(1)}ms '
        '(build ${build.toStringAsFixed(1)}, raster ${raster.toStringAsFixed(1)})',
      );
    }
  });
}

/// Debug builds only, so release never pays the sync reads.
(String, String)? screenshotRequest() {
  if (!kDebugMode) return null;
  final file = File('/tmp/pv-screenshot');
  if (!file.existsSync()) return null;
  final parts = file.readAsStringSync().trim().split(' ');
  return (parts[0], parts.length > 1 ? parts[1] : '');
}
