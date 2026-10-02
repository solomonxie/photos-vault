import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';

import 'app.dart';
import 'demo/demo_mode.dart';
import 'settings/app_store_region.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kProfileMode) _reportJank();
  await AppStoreRegion.load();
  try {
    await DemoMode.init();
  } catch (_) {
    // Demo plumbing must never be why the real app doesn't open.
  }
  runApp(const App());
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
