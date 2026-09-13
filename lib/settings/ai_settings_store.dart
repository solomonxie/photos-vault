import 'secure_store.dart';

/// Stores the user's OpenAI API key for the AI-powered People/Events smart
/// collections — see IMPLEMENTATION_PLAN.md T4.4.
class AiSettingsStore {
  AiSettingsStore({SecureStore? store}) : _store = store ?? const FlutterSecureStore();

  final SecureStore _store;

  static const _openAiApiKeyKey = 'openai_api_key_v1';

  Future<String?> readOpenAiApiKey() => _store.read(_openAiApiKeyKey);

  Future<void> saveOpenAiApiKey(String apiKey) => _store.write(_openAiApiKeyKey, apiKey);

  Future<void> clearOpenAiApiKey() => _store.delete(_openAiApiKeyKey);
}
