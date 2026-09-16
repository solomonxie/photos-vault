import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../settings/ai_settings_store.dart';
import 'ai_vendor.dart';

/// Thrown when an AI touch-up can't run — no key configured, no configured
/// vendor can edit images, or every one of them failed.
class AiImageEditException implements Exception {
  AiImageEditException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sends one photo plus a free-text prompt to an image-editing model and
/// returns the edited image's bytes. Only OpenAI and Google return images;
/// keys for the other vendors throw, which [AiSettingsStore.runWithKeys]
/// treats as a failure and falls through to the next key.
class AiImageEditService {
  AiImageEditService({
    AiSettingsStore? aiSettingsStore,
    http.Client? httpClient,
  }) : _aiSettingsStore = aiSettingsStore ?? AiSettingsStore(),
       _httpClient = httpClient ?? http.Client();

  final AiSettingsStore _aiSettingsStore;
  final http.Client _httpClient;

  Future<Uint8List> edit({
    required Uint8List bytes,
    required String prompt,
  }) async {
    try {
      return await _aiSettingsStore.runWithKeys(
        (key) => _runVendor(key.vendor, key.secret, bytes, prompt),
      );
    } on NoAiKeyException {
      throw AiImageEditException('No AI key configured');
    } on AiImageEditException {
      rethrow;
    } catch (e) {
      throw AiImageEditException('$e');
    }
  }

  Future<Uint8List> _runVendor(
    AiVendor vendor,
    String apiKey,
    Uint8List bytes,
    String prompt,
  ) => switch (vendor) {
    AiVendor.openai => _runOpenAi(apiKey, bytes, prompt),
    AiVendor.google => _runGoogle(apiKey, bytes, prompt),
    _ => throw AiImageEditException(
      "${vendor.name} keys can't edit images — add an OpenAI or Google key.",
    ),
  };

  Future<Uint8List> _runOpenAi(
    String apiKey,
    Uint8List bytes,
    String prompt,
  ) async {
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('https://api.openai.com/v1/images/edits'),
          )
          ..headers['Authorization'] = 'Bearer $apiKey'
          ..fields['model'] = 'gpt-image-1'
          ..fields['prompt'] = prompt
          ..files.add(
            http.MultipartFile.fromBytes('image', bytes, filename: 'photo.png'),
          );
    final response = await http.Response.fromStream(
      await _httpClient.send(request),
    );
    if (response.statusCode != 200) {
      throw AiImageEditException(
        'OpenAI request failed (${response.statusCode})',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final encoded = (body['data'] as List).first['b64_json'] as String?;
    if (encoded == null) throw AiImageEditException('OpenAI returned no image');
    return base64Decode(encoded);
  }

  Future<Uint8List> _runGoogle(
    String apiKey,
    Uint8List bytes,
    String prompt,
  ) async {
    final response = await _httpClient.post(
      Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-flash-image:generateContent?key=$apiKey',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt},
              {
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data': base64Encode(bytes),
                },
              },
            ],
          },
        ],
      }),
    );
    if (response.statusCode != 200) {
      throw AiImageEditException(
        'Google request failed (${response.statusCode})',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final parts =
        (body['candidates'] as List?)?.firstOrNull?['content']?['parts']
            as List?;
    for (final part in parts ?? const []) {
      final data = part['inlineData']?['data'] ?? part['inline_data']?['data'];
      if (data is String) return base64Decode(data);
    }
    throw AiImageEditException('Google returned no image');
  }
}
