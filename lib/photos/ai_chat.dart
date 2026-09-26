import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ai_vendor.dart';

/// One request to whichever vendor's key is in use, with a prompt and
/// optionally a picture.
///
/// Extracted from `ai_vision_service.dart` when a second thing needed to ask
/// a vendor something — the questions somebody types about a person or a
/// photo. The endpoints, the model names and the three request shapes were
/// already written and already the most likely thing to go stale; a second
/// copy of them would have gone stale separately.
///
/// [image] omitted sends a text-only question, which is what a question about
/// a person is: their profile is words, and paying to upload a photo to answer
/// it would be paying for nothing.
class AiChatException implements Exception {
  const AiChatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The vendor models used for a free-form question.
///
/// Deliberately the same ones the analysis pass uses: a second set would be a
/// second thing to keep current, and a vendor retiring a model should break
/// one place rather than two.
Future<String> askVendor({
  required AiVendor vendor,
  required String apiKey,
  required String prompt,
  required http.Client client,
  Uint8List? image,
  bool jsonMode = false,
  int maxTokens = 1024,
}) => switch (vendor) {
  AiVendor.openai => _openAiCompatible(
    vendorName: 'OpenAI',
    endpoint: 'https://api.openai.com/v1/chat/completions',
    model: 'gpt-4o-mini',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    image: image,
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.groq => _openAiCompatible(
    vendorName: 'Groq',
    endpoint: 'https://api.groq.com/openai/v1/chat/completions',
    model: image == null
        ? 'llama-3.3-70b-versatile'
        : 'llama-3.2-11b-vision-preview',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    image: image,
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.mistral => _openAiCompatible(
    vendorName: 'Mistral',
    endpoint: 'https://api.mistral.ai/v1/chat/completions',
    model: 'pixtral-12b-2409',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    image: image,
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.xai => _openAiCompatible(
    vendorName: 'xAI',
    endpoint: 'https://api.x.ai/v1/chat/completions',
    model: 'grok-2-vision-1212',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    image: image,
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.anthropic => _anthropic(
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    image: image,
    maxTokens: maxTokens,
  ),
  AiVendor.google => _google(
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    image: image,
  ),
};

Future<String> _openAiCompatible({
  required String vendorName,
  required String endpoint,
  required String model,
  required String apiKey,
  required String prompt,
  required http.Client client,
  required int maxTokens,
  Uint8List? image,
  bool jsonMode = false,
}) async {
  final response = await client.post(
    Uri.parse(endpoint),
    headers: {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'model': model,
      'max_tokens': maxTokens,
      if (jsonMode) 'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            if (image != null)
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,${base64Encode(image)}',
                },
              },
          ],
        },
      ],
    }),
  );
  if (response.statusCode != 200) {
    throw AiChatException(
      '$vendorName request failed (${response.statusCode})',
    );
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return (body['choices'] as List)[0]['message']['content'] as String;
}

Future<String> _anthropic({
  required String apiKey,
  required String prompt,
  required http.Client client,
  required int maxTokens,
  Uint8List? image,
}) async {
  final response = await client.post(
    Uri.parse('https://api.anthropic.com/v1/messages'),
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    },
    body: jsonEncode({
      'model': 'claude-haiku-4-5-20251001',
      'max_tokens': maxTokens,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            if (image != null)
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/jpeg',
                  'data': base64Encode(image),
                },
              },
          ],
        },
      ],
    }),
  );
  if (response.statusCode != 200) {
    throw AiChatException('Anthropic request failed (${response.statusCode})');
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return (body['content'] as List)[0]['text'] as String;
}

Future<String> _google({
  required String apiKey,
  required String prompt,
  required http.Client client,
  Uint8List? image,
}) async {
  final response = await client.post(
    Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      'gemini-1.5-flash:generateContent?key=$apiKey',
    ),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            if (image != null)
              {
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data': base64Encode(image),
                },
              },
          ],
        },
      ],
    }),
  );
  if (response.statusCode != 200) {
    throw AiChatException('Google request failed (${response.statusCode})');
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return (body['candidates'] as List)[0]['content']['parts'][0]['text']
      as String;
}
