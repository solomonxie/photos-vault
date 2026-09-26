import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../settings/ai_settings_store.dart';
import 'ai_chat.dart';
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

  /// The vendor call itself lives in `ai_chat.dart`, shared with the
  /// questions somebody types. `jsonMode` only for the vendor that honours it;
  /// the rest are asked for JSON by the prompt and mostly oblige, which is why
  /// [_parse] treats a bad reply as an error rather than a crash.
  Future<String> _runVendor(AiVendor vendor, String apiKey, Uint8List bytes) =>
      askVendor(
        vendor: vendor,
        apiKey: apiKey,
        prompt: _prompt,
        client: _httpClient,
        image: bytes,
        jsonMode: vendor == AiVendor.openai,
        maxTokens: 256,
      );

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
