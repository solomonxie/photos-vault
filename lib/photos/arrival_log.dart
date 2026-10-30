import 'package:flutter/foundation.dart';

/// How long new photos took to reach the grid, the last [capacity] times
/// any did: read in Developer options, on the phone, where it is slow.
class ArrivalLog {
  ArrivalLog._();

  static final shared = ArrivalLog._();

  static const capacity = 20;

  /// Newest first.
  final entries = ValueNotifier<List<Arrival>>(const []);

  /// [trigger]: what started it — `change` (Photos said so while open),
  /// `resume`, `launch`.
  ArrivalTrace start(String trigger) => ArrivalTrace._(this, trigger);

  void _add(Arrival arrival) {
    entries.value = [arrival, ...entries.value.take(capacity - 1)];
  }
}

class Arrival {
  const Arrival({
    required this.trigger,
    required this.at,
    required this.photos,
    required this.stages,
  });

  final String trigger;
  final DateTime at;
  final int photos;

  /// Stage name and time since [at], in order.
  final List<(String, Duration)> stages;

  Duration get total => stages.isEmpty ? Duration.zero : stages.last.$2;
}

/// One arrival in progress. Kept only if it brought photos.
class ArrivalTrace {
  ArrivalTrace._(this._log, this.trigger) : _at = DateTime.now() {
    _watch.start();
  }

  final ArrivalLog _log;
  final String trigger;
  final DateTime _at;
  final _watch = Stopwatch();
  final _stages = <(String, Duration)>[];
  bool _done = false;

  void mark(String stage) {
    if (!_done) _stages.add((stage, _watch.elapsed));
  }

  bool has(String stage) => _stages.any((s) => s.$1 == stage);

  void finish(int photos) {
    if (_done) return;
    _done = true;
    if (photos <= 0) return;
    _log._add(
      Arrival(
        trigger: trigger,
        at: _at,
        photos: photos,
        stages: List.unmodifiable(_stages),
      ),
    );
  }
}
