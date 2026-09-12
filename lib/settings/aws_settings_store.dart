import 'dart:convert';

import 'aws_settings.dart';
import 'secure_store.dart';

class AwsSettingsStore {
  AwsSettingsStore({SecureStore? store}) : _store = store ?? const FlutterSecureStore();

  final SecureStore _store;

  static const _key = 'aws_settings_v1';

  Future<AwsSettings> load() async {
    final raw = await _store.read(_key);
    if (raw == null || raw.isEmpty) return const AwsSettings();
    try {
      return AwsSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return const AwsSettings();
    }
  }

  Future<void> save(AwsSettings settings) => _store.write(_key, jsonEncode(settings.toJson()));

  Future<void> clear() => _store.delete(_key);
}
