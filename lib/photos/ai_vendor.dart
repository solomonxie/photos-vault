/// A vision-capable chat-completions provider AI Analysis can call — see
/// `ai_vision_service.dart` for the actual request per vendor and
/// `settings/ai_settings_store.dart` for how multiple configured keys (same
/// or different vendors) are tried in turn.
enum AiVendor { openai, anthropic, google, groq, mistral, xai }

/// Display name, a hint of what the key looks like (doubles as the "add
/// key" field's placeholder), and where to go make one — so adding a key
/// doesn't require already knowing each vendor's console.
class AiVendorMeta {
  const AiVendorMeta({
    required this.vendor,
    required this.name,
    required this.keyHint,
    required this.docsUrl,
  });

  final AiVendor vendor;
  final String name;
  final String keyHint;
  final String docsUrl;
}

/// DeepSeek is deliberately not here — this app's only AI feature is photo
/// *vision* analysis, and DeepSeek doesn't offer a vision-capable model, so
/// listing it would just be a key that can never work.
const aiVendors = <AiVendorMeta>[
  AiVendorMeta(
    vendor: AiVendor.openai,
    name: 'OpenAI',
    keyHint: 'sk-...',
    docsUrl: 'https://platform.openai.com/api-keys',
  ),
  AiVendorMeta(
    vendor: AiVendor.anthropic,
    name: 'Anthropic',
    keyHint: 'sk-ant-...',
    docsUrl: 'https://console.anthropic.com/settings/keys',
  ),
  AiVendorMeta(
    vendor: AiVendor.google,
    name: 'Google Gemini',
    keyHint: 'AIza...',
    docsUrl: 'https://aistudio.google.com/apikey',
  ),
  AiVendorMeta(
    vendor: AiVendor.groq,
    name: 'Groq',
    keyHint: 'gsk_...',
    docsUrl: 'https://console.groq.com/keys',
  ),
  AiVendorMeta(
    vendor: AiVendor.mistral,
    name: 'Mistral',
    keyHint: '...',
    docsUrl: 'https://console.mistral.ai/api-keys',
  ),
  AiVendorMeta(
    vendor: AiVendor.xai,
    name: 'xAI (Grok)',
    keyHint: 'xai-...',
    docsUrl: 'https://console.x.ai',
  ),
];

String aiVendorName(AiVendor vendor) =>
    aiVendors.firstWhere((v) => v.vendor == vendor).name;
