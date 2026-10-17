import 'dart:io';

import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart' show AssetEntity, LatLng;

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

  /// [ids]' assets that Photos has, by id, in one fetch per [assetsPage]:
  /// an id missing from the answer is gone. Null when it can't say (no
  /// channel, a failed call); ask per id then.
  Future<Map<String, AssetEntity>?> assets(Iterable<String> ids) async {
    if (!_supported) return null;
    final all = ids.toSet().toList();
    final out = <String, AssetEntity>{};
    try {
      for (var i = 0; i < all.length; i += assetsPage) {
        final page = all.sublist(i, (i + assetsPage).clamp(0, all.length));
        final raw = await _channel.invokeListMethod<Object?>('assets', page);
        if (raw == null) return null;
        for (final map in raw.whereType<Map>()) {
          final entity = entityOf(map.cast<String, Object?>());
          if (entity != null && page.contains(entity.id)) {
            out[entity.id] = entity;
          }
        }
      }
    } catch (_) {
      return null;
    }
    return out;
  }

  static const assetsPage = 200;

  /// photo_manager's own reading of the same map (`convertMapToAsset`).
  static AssetEntity? entityOf(Map<String, Object?> m) {
    final id = m['id'];
    if (id is! String) return null;
    num? n(String key) => m[key] is num ? m[key] as num : null;
    return AssetEntity(
      id: id,
      typeInt: n('type')?.toInt() ?? 0,
      width: n('width')?.toInt() ?? 0,
      height: n('height')?.toInt() ?? 0,
      duration: n('duration')?.toInt() ?? 0,
      isFavorite: m['favorite'] == true,
      title: m['title'] as String? ?? '',
      subtype: n('subtype')?.toInt() ?? 0,
      createDateSecond: n('createDt')?.toInt(),
      modifiedDateSecond: n('modifiedDt')?.toInt(),
      latLng: switch ((n('lat'), n('lng'))) {
        (final lat?, final lng?) => LatLng(
          latitude: lat.toDouble(),
          longitude: lng.toDouble(),
        ),
        _ => null,
      },
    );
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
