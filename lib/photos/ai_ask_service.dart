import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../settings/ai_settings_store.dart';
import 'ai_chat.dart';

/// A question somebody typed, answered by whichever AI key is configured.
///
/// No parsing, no schema: the answer is prose and goes on screen as prose.
/// Everything else the app asks a vendor is a fixed prompt with a fixed shape,
/// because the app has to do something with the reply. This is the one place
/// the reply is for a person to read.
class AiAskService {
  AiAskService({AiSettingsStore? aiSettingsStore, http.Client? httpClient})
    : _aiSettingsStore = aiSettingsStore ?? AiSettingsStore(),
      _httpClient = httpClient ?? http.Client();

  final AiSettingsStore _aiSettingsStore;
  final http.Client _httpClient;

  /// [context] is what the app knows and the vendor does not — a profile as
  /// plain text, or nothing at all. Kept separate from [question] so the
  /// prompt can say which is which, and so a caller cannot accidentally send
  /// a profile when it meant to send only a question.
  Future<String> ask({
    required String question,
    String context = '',
    Uint8List? image,
  }) async {
    final prompt = [
      if (context.isNotEmpty) ...['Here is what I know:', context, ''],
      'My question:',
      question,
    ].join('\n');
    return _aiSettingsStore.runWithKeys(
      (key) => askVendor(
        vendor: key.vendor,
        apiKey: key.secret,
        prompt: prompt,
        client: _httpClient,
        image: image,
      ),
    );
  }
}
