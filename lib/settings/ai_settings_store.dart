import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../photos/ai_vendor.dart';
import 'secure_store.dart';

/// Sequential is sticky — every call starts from the same key, only moving
/// on once that key itself errors (rate limit, quota, revoked, ...).
/// Round-robin instead advances the starting point on every single call,
/// win or lose, to spread load across keys rather than favor one.
enum AiKeyStrategy { sequential, roundRobin }

/// One configured AI key. [requestCount] is a plain usage counter (every
/// attempt, success or not) shown next to each key in Settings so it's
/// visible which ones are actually carrying traffic.
class AiKeyMeta {
  const AiKeyMeta({
    required this.id,
    required this.vendor,
    required this.secret,
    this.requestCount = 0,
  });

  final String id;
  final AiVendor vendor;
  final String secret;
  final int requestCount;

  AiKeyMeta withRequestCount(int value) =>
      AiKeyMeta(id: id, vendor: vendor, secret: secret, requestCount: value);

  Map<String, Object?> toJson() => {
    'id': id,
    'vendor': vendor.name,
    'secret': secret,
    'requestCount': requestCount,
  };

  static AiKeyMeta fromJson(Map<String, Object?> json) => AiKeyMeta(
    id: json['id'] as String,
    vendor: AiVendor.values.byName(json['vendor'] as String),
    secret: json['secret'] as String,
    requestCount: json['requestCount'] as int? ?? 0,
  );
}

/// Thrown by [AiSettingsStore.runWithKeys] when nothing is configured.
class NoAiKeyException implements Exception {
  @override
  String toString() => 'No AI key configured.';
}

/// Stores every AI key the user has added (any mix of vendors) plus the
/// fallback [AiKeyStrategy] between them — powers the People/Events smart
/// collections. See IMPLEMENTATION_PLAN.md T4.4.
class AiSettingsStore {
  AiSettingsStore({SecureStore? store, Uuid? uuid})
    : _store = store ?? const FlutterSecureStore(),
      _uuid = uuid ?? const Uuid();

  final SecureStore _store;
  final Uuid _uuid;

  static const _keysKey = 'ai_keys_v1';
  static const _strategyKey = 'ai_key_strategy_v1';
  static const _cursorKey = 'ai_key_cursor_v1';

  /// Pre-multi-vendor storage slot — migrated into [_keysKey] the first
  /// time it's read after this feature shipped.
  static const _legacyOpenAiKey = 'openai_api_key_v1';

  Future<List<AiKeyMeta>> listKeys() async {
    final raw = await _store.read(_keysKey);
    if (raw != null) {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => AiKeyMeta.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    final legacy = await _store.read(_legacyOpenAiKey);
    if (legacy == null || legacy.isEmpty) {
      await _writeKeys(const []);
      return const [];
    }
    final migrated = [
      AiKeyMeta(id: _uuid.v4(), vendor: AiVendor.openai, secret: legacy),
    ];
    await _writeKeys(migrated);
    await _store.delete(_legacyOpenAiKey);
    return migrated;
  }

  /// Every vendor key and the rotation state around them. The legacy slot
  /// too: an install that never opened the AI screen since the migration
  /// still has its old key sitting there unmigrated.
  Future<void> clearAll() async {
    for (final key in const [
      _keysKey,
      _strategyKey,
      _cursorKey,
      _legacyOpenAiKey,
    ]) {
      await _store.delete(key);
    }
  }

  Future<void> _writeKeys(List<AiKeyMeta> keys) =>
      _store.write(_keysKey, jsonEncode(keys.map((k) => k.toJson()).toList()));

  Future<String> addKey(AiVendor vendor, String secret) async {
    final keys = await listKeys();
    final id = _uuid.v4();
    await _writeKeys([
      ...keys,
      AiKeyMeta(id: id, vendor: vendor, secret: secret),
    ]);
    return id;
  }

  Future<void> removeKey(String id) async {
    final keys = await listKeys();
    await _writeKeys(keys.where((k) => k.id != id).toList());
  }

  /// Swaps a key with its neighbor — the reordering UI is a pair of ↑/↓
  /// buttons per row rather than a drag gesture.
  Future<void> moveKey(String id, int direction) async {
    final keys = await listKeys();
    final idx = keys.indexWhere((k) => k.id == id);
    final swapWith = idx + direction;
    if (idx < 0 || swapWith < 0 || swapWith >= keys.length) return;
    final next = [...keys];
    final tmp = next[idx];
    next[idx] = next[swapWith];
    next[swapWith] = tmp;
    await _writeKeys(next);
  }

  Future<void> _bumpRequestCount(String id) async {
    final keys = await listKeys();
    await _writeKeys([
      for (final k in keys)
        k.id == id ? k.withRequestCount(k.requestCount + 1) : k,
    ]);
  }

  Future<AiKeyStrategy> getStrategy() async {
    final raw = await _store.read(_strategyKey);
    return raw == 'roundRobin'
        ? AiKeyStrategy.roundRobin
        : AiKeyStrategy.sequential;
  }

  Future<void> setStrategy(AiKeyStrategy value) =>
      _store.write(_strategyKey, value.name);

  Future<int> _getCursor() async {
    final raw = await _store.read(_cursorKey);
    return raw == null ? 0 : int.tryParse(raw) ?? 0;
  }

  Future<void> _setCursor(int value) => _store.write(_cursorKey, '$value');

  /// Tries each configured key in turn — starting point depends on
  /// [AiKeyStrategy] — until [call] succeeds. A failure falls through to
  /// the next configured key before giving up, so one dead/rate-limited
  /// key doesn't take AI Analysis down entirely.
  Future<T> runWithKeys<T>(Future<T> Function(AiKeyMeta key) call) async {
    final keys = await listKeys();
    if (keys.isEmpty) throw NoAiKeyException();
    final strategy = await getStrategy();
    final startAt = (await _getCursor()) % keys.length;
    final order = [...keys.sublist(startAt), ...keys.sublist(0, startAt)];
    if (strategy == AiKeyStrategy.roundRobin) {
      await _setCursor((startAt + 1) % keys.length);
    }

    Object? lastError;
    for (var i = 0; i < order.length; i++) {
      final key = order[i];
      await _bumpRequestCount(key.id);
      try {
        return await call(key);
      } catch (e) {
        lastError = e;
        if (strategy == AiKeyStrategy.sequential) {
          await _setCursor((startAt + i + 1) % keys.length);
        }
      }
    }
    throw lastError ?? NoAiKeyException();
  }
}
