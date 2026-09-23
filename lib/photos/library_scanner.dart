import 'package:flutter/foundation.dart';

/// The camera-roll re-read, on its own and out of sight.
///
/// Deliberately not a row in the analyze queue, and not configurable. It
/// isn't work anybody chose: it's the app noticing what Photos did while
/// it wasn't looking, and a library that stopped noticing would quietly
/// stop showing new photos — which is not a thing a pause switch should
/// be able to do. Analysis is the opposite: it costs battery and,
/// optionally, money, so it stays in a queue you can see, pace and stop.
///
/// One pass at a time, and at most one every [interval] unless forced.
class LibraryScanner {
  LibraryScanner({
    required this.scan,
    this.scanRecent,
    this.interval = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The pass itself, owned by whoever redraws as its pages arrive.
  final Future<void> Function() scan;

  /// The newest photos only — see [runRecent].
  final Future<void> Function()? scanRecent;

  /// How long a re-read stays good for. Without it, coming back to the
  /// library screen twice in a second would read Photos twice.
  final Duration interval;

  final DateTime Function() _now;

  /// For a caller that wants to show something while it works. Nothing in
  /// the app does today — that's the point — but a scan that never says
  /// anything is impossible to debug.
  final ValueNotifier<bool> running = ValueNotifier(false);

  DateTime? _lastAt;
  Future<void>? _inFlight;
  Future<void>? _recentInFlight;

  /// The near end of the library, every time the app opens or comes back,
  /// with no interval and no waiting on [run].
  ///
  /// A full pass is minutes long on a real library, and it holds the lane:
  /// [run] joins the one already going rather than starting a second. That
  /// is right for the backstop and wrong for the reason anybody reopens the
  /// app — they just took a photo, or just deleted one, and a scan halfway
  /// through 2014 will not reach either for a while. This lane is short,
  /// bounded and always allowed to run, so the newest photos are current
  /// before the rest of the library has been looked at.
  Future<void> runRecent() async {
    final scan = scanRecent;
    if (scan == null) return;
    final inFlight = _recentInFlight;
    if (inFlight != null) return inFlight;
    final future = _guarded(scan);
    _recentInFlight = future;
    try {
      await future;
    } finally {
      _recentInFlight = null;
    }
  }

  /// Photos unavailable, permission withdrawn mid-pass — swallowed so the
  /// next round tries again.
  static Future<void> _guarded(Future<void> Function() scan) async {
    try {
      await scan();
    } catch (_) {}
  }

  /// [force] ignores [interval] — what coming back from Photos means,
  /// where the whole point is that something may have changed over there.
  Future<void> run({bool force = false}) async {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final last = _lastAt;
    if (!force && last != null && _now().difference(last) < interval) return;
    final future = _run();
    _inFlight = future;
    try {
      await future;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _run() async {
    running.value = true;
    try {
      await scan();
      _lastAt = _now();
    } catch (_) {
      // Photos unavailable, permission withdrawn mid-pass — left unmarked
      // so the next round tries again rather than waiting out [interval].
    } finally {
      running.value = false;
    }
  }

  void dispose() => running.dispose();
}
