import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'app_localizations.dart';

/// A failure as shown on screen: localized when it is a known kind, and
/// never with a URL in it — a query string can carry a signature or a key.
String failureText(AppLocalizations l10n, Object error) => switch (error) {
  SocketException() ||
  TlsException() ||
  http.ClientException() ||
  TimeoutException() => l10n.errorOffline,
  _ => _withoutUrls('$error'),
};

String _withoutUrls(String text) =>
    text.replaceAll(RegExp(r',?\s*(uri=)?[a-z][a-z0-9+.-]*://\S+'), '').trim();
