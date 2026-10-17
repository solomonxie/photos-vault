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
/// Between full passes, [runChanges] catches up from Photos' own change
/// history.
class LibraryScanner {
  LibraryScanner({
    required this.scan,
    this.scanRecent,
    this.scanChanges,
    this.lastFullPass,
    this.interval = const Duration(days: 1),
    this.before,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Awaited before every pass: a fresh install's restore, so the scan
  /// doesn't race it to every asset (the restore merges with what it finds
  /// either way; this just leaves it less to merge).
  final Future<void> Function()? before;

  /// The pass itself, owned by whoever redraws as its pages arrive.
  final Future<void> Function() scan;

  /// The newest photos only — see [runRecent].
  final Future<void> Function()? scanRecent;

  /// What changed since the last pass; false when it can't say, which
  /// forces the full pass — see [runChanges].
  final Future<bool> Function()? scanChanges;

  /// When the last full pass finished, across launches.
  final Future<DateTime?> Function()? lastFullPass;

  /// How long a full re-read stays good for. Between passes, the change
  /// history and the notifications keep up; this is the backstop.
  final Duration interval;

  final DateTime Function() _now;

  DateTime? _lastAt;
  bool _lastLoaded = false;
  Future<void>? _inFlight;
  Future<void>? _recentInFlight;
  Future<void>? _changesInFlight;

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
    final future = _guarded(() async {
      await _waitBefore();
      await scan();
    });
    _recentInFlight = future;
    try {
      await future;
    } finally {
      _recentInFlight = null;
    }
  }

  /// Opening the app or coming back to it: the changes since the last
  /// pass, then the full pass only when it is due or the changes couldn't
  /// be had (no history, an expired token, access changed).
  Future<void> runChanges() async {
    final inFlight = _changesInFlight;
    if (inFlight != null) return inFlight;
    final future = () async {
      await _waitBefore();
      var covered = false;
      try {
        covered = await scanChanges?.call() ?? false;
      } catch (_) {}
      await run(force: !covered);
    }();
    _changesInFlight = future;
    try {
      await future;
    } finally {
      _changesInFlight = null;
    }
  }

  /// Photos unavailable, permission withdrawn mid-pass — swallowed so the
  /// next round tries again.
  static Future<void> _guarded(Future<void> Function() scan) async {
    try {
      await scan();
    } catch (_) {}
  }

  /// [force] ignores [interval]: what [runChanges] asks for when the
  /// change history can't vouch for what moved.
  Future<void> run({bool force = false}) async {
    var inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    if (!force && !_lastLoaded) {
      _lastLoaded = true;
      try {
        _lastAt ??= await lastFullPass?.call();
      } catch (_) {}
      inFlight = _inFlight;
      if (inFlight != null) return inFlight;
    }
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

  Future<void> _waitBefore() async {
    try {
      await before?.call();
    } catch (_) {}
  }

  Future<void> _run() async {
    await _waitBefore();
    try {
      await scan();
      _lastAt = _now();
    } catch (_) {
      // Photos unavailable, permission withdrawn mid-pass — left unmarked
      // so the next round tries again rather than waiting out [interval].
    }
  }
}
