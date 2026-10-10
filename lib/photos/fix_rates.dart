import 'dart:convert';

import '../storage/asset_record_store.dart';

/// How long each kind of fix has actually taken on this phone, so an
/// estimate is this phone's and this network's, not a guess.
///
/// A re-encode or an upload scales with the file, so it is learned per
/// byte; a rename or a delete is a few round trips whatever the size, so it
/// is learned per item. Until a kind has been timed a few times, a modest
/// built-in rate stands in.
class FixRates {
  FixRates(this.store);

  final AssetRecordStore store;
  static const _key = 'fix_rates_v1';

  /// Timed runs before the learned rate replaces the built-in one.
  static const _trusted = 3;

  final Map<String, _Tally> _tallies = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await store.getAppState(_key);
      if (raw == null) return;
      for (final MapEntry(key: k, value: v)
          in (jsonDecode(raw) as Map).cast<String, dynamic>().entries) {
        final list = (v as List).cast<num>();
        _tallies[k] = _Tally(list[0].toInt(), list[1].toInt(), list[2].toInt());
      }
    } catch (_) {
      // Unreadable: the built-in rates stand in.
    }
  }

  /// [kind] is a key from the caller: `optimize:video`, `rename`, ….
  Future<void> record(
    String kind, {
    required Duration took,
    required int bytes,
    required int items,
  }) async {
    if (items == 0) return;
    final t = _tallies[kind] ?? _Tally(0, 0, 0);
    _tallies[kind] = _Tally(
      t.ms + took.inMilliseconds,
      t.bytes + bytes,
      t.items + items,
    );
    await store.setAppState(
      _key,
      jsonEncode({
        for (final e in _tallies.entries)
          e.key: [e.value.ms, e.value.bytes, e.value.items],
      }),
    );
  }

  /// What [items] of [kind] totalling [bytes] should take.
  Duration estimate(
    String kind, {
    required bool bySize,
    required int bytes,
    required int items,
    required Duration perItem,
    required double bytesPerSecond,
  }) {
    final t = _tallies[kind];
    final learned = t != null && t.items >= _trusted;
    if (bySize) {
      final rate = learned && t.ms > 0 && t.bytes > 0
          ? t.bytes / (t.ms / 1000)
          : bytesPerSecond;
      return Duration(milliseconds: (bytes / rate * 1000).round());
    }
    final each = learned ? t.ms ~/ t.items : perItem.inMilliseconds;
    return Duration(milliseconds: each * items);
  }
}

class _Tally {
  const _Tally(this.ms, this.bytes, this.items);

  final int ms;
  final int bytes;
  final int items;
}
