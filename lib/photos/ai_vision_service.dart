import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../settings/ai_settings_store.dart';
import 'ai_analysis.dart';
import 'ai_vendor.dart';

/// Thrown when analysis can't run — no AI key configured, or every
/// configured vendor rejected/failed the request.
class AiAnalysisException implements Exception {
  AiAnalysisException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Calls a vision-capable chat-completions API to describe one photo —
/// people count and a short event/scene label — for the People/Events
/// smart collections. Opt-in: only runs when the user has saved at least
/// one AI key in [AiSettingsStore], which also picks which configured key
/// (and thus vendor) handles each call and retries the next one on
/// failure. See IMPLEMENTATION_PLAN.md T4.4.
class AiVisionService {
  AiVisionService({AiSettingsStore? aiSettingsStore, http.Client? httpClient})
    : _aiSettingsStore = aiSettingsStore ?? AiSettingsStore(),
      _httpClient = httpClient ?? http.Client();

  static const _prompt =
      'Reply with JSON only, no prose: '
      '{"people_count": <integer, 0 if none>, '
      '"event_label": "<2-4 word scene or event description>", '
      '"tags": ["<up to 5 short lowercase subject tags>"], '
      '"description": "<one plain sentence describing the photo, '
      'as a caption its owner would write>"}.';

  final AiSettingsStore _aiSettingsStore;
  final http.Client _httpClient;

  Future<AiPhotoAnalysis> analyze({
    required String localId,
    required File imageFile,
  }) async {
    final bytes = await imageFile.readAsBytes();
    final String content;
    try {
      content = await _aiSettingsStore.runWithKeys(
        (key) => _runVendor(key.vendor, key.secret, bytes),
      );
    } on NoAiKeyException {
      throw AiAnalysisException('No AI key configured');
    } catch (e) {
      throw AiAnalysisException('AI analysis failed: $e');
    }
    return _parse(localId, content);
  }

  Future<String> _runVendor(AiVendor vendor, String apiKey, Uint8List bytes) =>
      switch (vendor) {
        AiVendor.openai => _runOpenAiCompatible(
          vendorName: 'OpenAI',
          endpoint: 'https://api.openai.com/v1/chat/completions',
          model: 'gpt-4o-mini',
          apiKey: apiKey,
          bytes: bytes,
          jsonMode: true,
        ),
        // Vision-capable models on each vendor's own OpenAI-compatible
        // chat/completions endpoint — same `image_url` content-block shape as
        // OpenAI itself. Model names are the most likely to go stale if a
        // vendor retires/renames its vision model.
        AiVendor.groq => _runOpenAiCompatible(
          vendorName: 'Groq',
          endpoint: 'https://api.groq.com/openai/v1/chat/completions',
          model: 'llama-3.2-11b-vision-preview',
          apiKey: apiKey,
          bytes: bytes,
        ),
        AiVendor.mistral => _runOpenAiCompatible(
          vendorName: 'Mistral',
          endpoint: 'https://api.mistral.ai/v1/chat/completions',
          model: 'pixtral-12b-2409',
          apiKey: apiKey,
          bytes: bytes,
        ),
        AiVendor.xai => _runOpenAiCompatible(
          vendorName: 'xAI',
          endpoint: 'https://api.x.ai/v1/chat/completions',
          model: 'grok-2-vision-1212',
          apiKey: apiKey,
          bytes: bytes,
        ),
        AiVendor.anthropic => _runAnthropic(apiKey, bytes),
        AiVendor.google => _runGoogle(apiKey, bytes),
      };

  Future<String> _runOpenAiCompatible({
    required String vendorName,
    required String endpoint,
    required String model,
    required String apiKey,
    required Uint8List bytes,
    bool jsonMode = false,
  }) async {
    final base64Image = base64Encode(bytes);
    final response = await _httpClient.post(
      Uri.parse(endpoint),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        if (jsonMode) 'response_format': {'type': 'json_object'},
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
      throw AiAnalysisException(
        '$vendorName request failed (${response.statusCode})',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['choices'] as List)[0]['message']['content'] as String;
  }

  Future<String> _runAnthropic(String apiKey, Uint8List bytes) async {
    final base64Image = base64Encode(bytes);
    final response = await _httpClient.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': 'claude-haiku-4-5-20251001',
        'max_tokens': 256,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': _prompt},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/jpeg',
                  'data': base64Image,
                },
              },
            ],
          },
        ],
      }),
    );
    if (response.statusCode != 200) {
      throw AiAnalysisException(
        'Anthropic request failed (${response.statusCode})',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['content'] as List)[0]['text'] as String;
  }

  Future<String> _runGoogle(String apiKey, Uint8List bytes) async {
    final base64Image = base64Encode(bytes);
    final response = await _httpClient.post(
      Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': _prompt},
              {
                'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image},
              },
            ],
          },
        ],
      }),
    );
    if (response.statusCode != 200) {
      throw AiAnalysisException(
        'Google request failed (${response.statusCode})',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['candidates'] as List)[0]['content']['parts'][0]['text']
        as String;
  }

  AiPhotoAnalysis _parse(String localId, String content) {
    try {
      final parsed = jsonDecode(content) as Map<String, dynamic>;
      final eventLabel = (parsed['event_label'] as String?)?.trim() ?? '';
      final tags = parsed['tags'];
      return AiPhotoAnalysis(
        localId: localId,
        peopleCount: (parsed['people_count'] as num?)?.toInt() ?? 0,
        eventLabel: eventLabel,
        analyzedAt: DateTime.now(),
        tags: [
          if (tags is List)
            for (final tag in tags)
              if (tag is String && tag.trim().isNotEmpty) tag.trim(),
        ],
        description: (parsed['description'] as String?)?.trim() ?? '',
      );
    } catch (_) {
      throw AiAnalysisException('Could not parse AI response');
    }
  }
}
