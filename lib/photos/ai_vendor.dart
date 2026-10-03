import '../settings/app_store_region.dart';

/// A vision-capable chat-completions provider AI Analysis can call — see
/// `ai_vision_service.dart` for the actual request per vendor and
/// `settings/ai_settings_store.dart` for how multiple configured keys (same
/// or different vendors) are tried in turn.
enum AiVendor {
  openai,
  anthropic,
  google,
  groq,
  mistral,
  xai,
  deepseek,
  qwen,
  zhipu,
  moonshot,
}

/// Display name, a hint of what the key looks like (doubles as the "add
/// key" field's placeholder), and where to go make one — so adding a key
/// doesn't require already knowing each vendor's console.
class AiVendorMeta {
  const AiVendorMeta({
    required this.vendor,
    required this.name,
    required this.keyHint,
    required this.docsUrl,
    this.region = AppStoreRegion.us,
  });

  final AiVendor vendor;
  final String name;
  final String keyHint;
  final String docsUrl;

  /// The only storefront that offers it: China allows only vendors
  /// licensed there, and those endpoints are China-region.
  final AppStoreRegion region;
}

/// Use [aiVendorsFor] for anything shown or called: the storefront decides
/// which apply. Order is the picker's order.
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
  AiVendorMeta(
    vendor: AiVendor.deepseek,
    name: 'DeepSeek',
    keyHint: 'sk-...',
    docsUrl: 'https://platform.deepseek.com/api_keys',
    region: AppStoreRegion.cn,
  ),
  AiVendorMeta(
    vendor: AiVendor.qwen,
    name: '通义千问 Qwen',
    keyHint: 'sk-...',
    docsUrl: 'https://bailian.console.aliyun.com/?apiKey=1',
    region: AppStoreRegion.cn,
  ),
  AiVendorMeta(
    vendor: AiVendor.zhipu,
    name: '智谱 GLM',
    keyHint: '...',
    docsUrl: 'https://open.bigmodel.cn/usercenter/apikeys',
    region: AppStoreRegion.cn,
  ),
  AiVendorMeta(
    vendor: AiVendor.moonshot,
    name: 'Kimi (Moonshot)',
    keyHint: 'sk-...',
    docsUrl: 'https://platform.moonshot.cn/console/api-keys',
    region: AppStoreRegion.cn,
  ),
];

/// Off in China for now (2026-10): App Review there asks generative-AI
/// apps for local permits, and this is a bring-your-own-key extra. The
/// licensed vendors above stay listed for when it comes back.
const aiInChina = false;

/// Whether this storefront gets AI at all — every entry point checks it.
bool get aiOffered => AppStoreRegion.current != AppStoreRegion.cn || aiInChina;

List<AiVendorMeta> aiVendorsFor(AppStoreRegion region) =>
    region == AppStoreRegion.cn && !aiInChina
    ? const []
    : aiVendors.where((v) => v.region == region).toList();

bool aiVendorAllowed(AiVendor vendor, AppStoreRegion region) =>
    aiVendorsFor(region).any((v) => v.vendor == vendor);

String aiVendorName(AiVendor vendor) =>
    aiVendors.firstWhere((v) => v.vendor == vendor).name;
