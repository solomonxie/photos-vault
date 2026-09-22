import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'app.dart';

void main() {
  if (kProfileMode) _reportJank();
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
