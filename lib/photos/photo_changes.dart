import 'dart:io';

import 'package:flutter/services.dart';

import '../demo/demo_flag.dart';
import 'photo_library_change.dart';

/// What PhotoKit's change history says moved since a token, and the token
/// to ask from next time.
class PhotoChangeDelta {
  const PhotoChangeDelta({required this.change, required this.token});

  final PhotoLibraryChange change;
  final String token;
}

/// PhotoKit's persistent change history (iOS 16+), over a platform channel:
/// what changed in Photos while this app wasn't running. Null for anything
/// it can't say — no channel, iOS 15, an expired token — which the caller
/// answers with a full pass.
class PhotoChanges {
  PhotoChanges({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'byo.photos/photo_changes';

  final MethodChannel _channel;

  bool get _supported => Platform.isIOS && !DemoFlag.active;

  /// The library's current change token.
  Future<String?> token() async {
    if (!_supported) return null;
    try {
      return await _channel.invokeMethod<String>('token');
    } catch (_) {
      return null;
    }
  }

  Future<PhotoChangeDelta?> since(String token) async {
    if (!_supported) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'since',
        token,
      );
      return raw == null ? null : parse(raw);
    } catch (_) {
      return null;
    }
  }

  static PhotoChangeDelta? parse(Map<String, Object?> raw) {
    final next = raw['token'];
    if (next is! String) return null;
    return PhotoChangeDelta(
      change: PhotoLibraryChange(
        created: _ids(raw['inserted']),
        updated: _ids(raw['updated']),
        deleted: _ids(raw['deleted']),
      ),
      token: next,
    );
  }

  static Set<String> _ids(Object? value) =>
      value is List ? {...value.whereType<String>()} : const {};
}
