import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../settings/ai_settings_store.dart';
import 'ai_analysis.dart';

/// Thrown when analysis can't run — no API key configured, or OpenAI
/// rejected the request.
class AiAnalysisException implements Exception {
  AiAnalysisException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Calls OpenAI's vision-capable chat completions API to describe one photo
/// — people count and a short event/scene label — for the People/Events
/// smart collections. Opt-in: only runs when the user has saved their own
/// API key in [AiSettingsStore]. See IMPLEMENTATION_PLAN.md T4.4.
class AiVisionService {
  AiVisionService({AiSettingsStore? aiSettingsStore, http.Client? httpClient})
    : _aiSettingsStore = aiSettingsStore ?? AiSettingsStore(),
      _httpClient = httpClient ?? http.Client();

  static const _endpoint = 'https://api.openai.com/v1/chat/completions';
  static const _model = 'gpt-4o-mini';
  static const _prompt =
      'Reply with JSON only, no prose: '
      '{"people_count": <integer, 0 if none>, "event_label": "<2-4 word scene or event description>"}.';

  final AiSettingsStore _aiSettingsStore;
  final http.Client _httpClient;

  Future<AiPhotoAnalysis> analyze({required String localId, required File imageFile}) async {
    final apiKey = await _aiSettingsStore.readOpenAiApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw AiAnalysisException('No OpenAI API key configured');
    }

    final base64Image = base64Encode(await imageFile.readAsBytes());
    final response = await _httpClient.post(
      Uri.parse(_endpoint),
      headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': _model,
        'response_format': {'type': 'json_object'},
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': _prompt},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$base64Image'},
              },
            ],
          },
        ],
      }),
    );

    if (response.statusCode != 200) {
      throw AiAnalysisException('OpenAI request failed (${response.statusCode})');
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final content = (body['choices'] as List)[0]['message']['content'] as String;
      final parsed = jsonDecode(content) as Map<String, dynamic>;
      final eventLabel = (parsed['event_label'] as String?)?.trim() ?? '';
      return AiPhotoAnalysis(
        localId: localId,
        peopleCount: (parsed['people_count'] as num?)?.toInt() ?? 0,
        eventLabel: eventLabel,
        analyzedAt: DateTime.now(),
      );
    } catch (_) {
      throw AiAnalysisException('Could not parse OpenAI response');
    }
  }
}
