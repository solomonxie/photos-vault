import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_vendor.dart';

/// One request to whichever vendor's key is in use, with a text prompt.
///
/// Extracted from `ai_vision_service.dart` when a second thing needed to ask
/// a vendor something — the questions somebody types about a person or a
/// photo. The endpoints, the model names and the three request shapes were
/// already written and already the most likely thing to go stale; a second
/// copy of them would have gone stale separately.
///
/// Text only, by design: no photo is ever sent to an AI service.
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
  bool jsonMode = false,
  int maxTokens = 1024,
  Duration timeout = const Duration(seconds: 60),
}) =>
    _dispatch(
      vendor: vendor,
      apiKey: apiKey,
      prompt: prompt,
      client: client,
      jsonMode: jsonMode,
      maxTokens: maxTokens,
    ).timeout(
      timeout,
      // A retired model can leave a request open forever rather than fail.
      onTimeout: () => throw AiChatException(
        '${aiVendorName(vendor)} timed out after ${timeout.inSeconds}s',
      ),
    );

/// A one-word round trip, to tell a bad key from a good one before saving.
Future<void> checkVendorKey({
  required AiVendor vendor,
  required String apiKey,
  required http.Client client,
}) => askVendor(
  vendor: vendor,
  apiKey: apiKey,
  prompt: 'Reply with OK.',
  client: client,
  maxTokens: 5,
  timeout: const Duration(seconds: 10),
);

Future<String> _dispatch({
  required AiVendor vendor,
  required String apiKey,
  required String prompt,
  required http.Client client,
  required bool jsonMode,
  required int maxTokens,
}) => switch (vendor) {
  AiVendor.deepseek => _openAiCompatible(
    vendorName: 'DeepSeek',
    endpoint: 'https://api.deepseek.com/chat/completions',
    model: 'deepseek-v4-pro',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.openai => _openAiCompatible(
    vendorName: 'OpenAI',
    endpoint: 'https://api.openai.com/v1/chat/completions',
    model: 'gpt-4o-mini',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.groq => _openAiCompatible(
    vendorName: 'Groq',
    endpoint: 'https://api.groq.com/openai/v1/chat/completions',
    model: 'llama-3.3-70b-versatile',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.mistral => _openAiCompatible(
    vendorName: 'Mistral',
    endpoint: 'https://api.mistral.ai/v1/chat/completions',
    model: 'mistral-small-latest',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
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
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.qwen => _openAiCompatible(
    vendorName: 'Qwen',
    endpoint:
        'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    model: 'qwen-plus',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.zhipu => _openAiCompatible(
    vendorName: 'Zhipu',
    endpoint: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    model: 'glm-4-plus',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.moonshot => _openAiCompatible(
    vendorName: 'Moonshot',
    endpoint: 'https://api.moonshot.cn/v1/chat/completions',
    model: 'moonshot-v1-8k',
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    jsonMode: jsonMode,
    maxTokens: maxTokens,
  ),
  AiVendor.anthropic => _anthropic(
    apiKey: apiKey,
    prompt: prompt,
    client: client,
    maxTokens: maxTokens,
  ),
  AiVendor.google => _google(apiKey: apiKey, prompt: prompt, client: client),
};

Future<String> _openAiCompatible({
  required String vendorName,
  required String endpoint,
  required String model,
  required String apiKey,
  required String prompt,
  required http.Client client,
  required int maxTokens,
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
        {'role': 'user', 'content': prompt},
      ],
    }),
  );
  if (response.statusCode != 200) throw _failed(vendorName, response);
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return (body['choices'] as List)[0]['message']['content'] as String;
}

Future<String> _anthropic({
  required String apiKey,
  required String prompt,
  required http.Client client,
  required int maxTokens,
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
          ],
        },
      ],
    }),
  );
  if (response.statusCode != 200) throw _failed('Anthropic', response);
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return (body['content'] as List)[0]['text'] as String;
}

Future<String> _google({
  required String apiKey,
  required String prompt,
  required http.Client client,
}) async {
  final response = await client.post(
    // The key in a header, never the URL: a failed request's message
    // carries the URL onto the screen (05#25).
    Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      'gemini-2.5-flash:generateContent',
    ),
    headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
    body: jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
          ],
        },
      ],
    }),
  );
  if (response.statusCode != 200) throw _failed('Google', response);
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return (body['candidates'] as List)[0]['content']['parts'][0]['text']
      as String;
}

/// The status and the vendor's own reason, which is what says "model
/// retired" or "quota" (05#20). Short, and never the request.
AiChatException _failed(String vendor, http.Response response) {
  String? reason;
  try {
    final body = jsonDecode(response.body);
    final error = body is Map ? body['error'] : null;
    reason = switch (error) {
      {'message': final String m} => m,
      final String m => m,
      _ => null,
    };
  } catch (_) {
    // Not JSON: the status alone.
  }
  final status = '$vendor request failed (${response.statusCode})';
  if (reason == null || reason.trim().isEmpty) return AiChatException(status);
  final short = reason.trim().replaceAll(RegExp(r'\s+'), ' ');
  return AiChatException(
    '$status: ${short.length > 160 ? '${short.substring(0, 160)}…' : short}',
  );
}
