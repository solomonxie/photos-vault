import 'package:flutter/widgets.dart';

/// Completes once the first frame is on screen, so start-up maintenance
/// never queues ahead of the queries that paint it. Never, in a headless
/// engine (background sync): its work waits for a foreground launch.
/// At once where there is no binding (plain tests).
Future<void> afterFirstFrame() async {
  final WidgetsBinding binding;
  try {
    binding = WidgetsBinding.instance;
  } catch (_) {
    return;
  }
  await binding.waitUntilFirstFrameRasterized;
}
