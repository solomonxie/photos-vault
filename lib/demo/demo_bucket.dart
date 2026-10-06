import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../settings/s3_backup_target.dart';
import '../settings/s3_listing.dart';
import 'demo_flag.dart';
import 'demo_images.dart';
import 'demo_seed.dart';

/// A bucket that exists only in demo mode: listed from the seed and
/// previewed from the same drawn pictures, with no network involved.
class DemoBucket {
  static const bucket = 'demo-photos';
  static const prefix = 'photos-vault/';
  static const _backedUp = {'uploaded', 'cloudOnly'};

  static bool owns(S3BackupTarget target) =>
      DemoFlag.active && target.bucket == bucket;

  static Future<List<Map<String, dynamic>>> _seeded() async {
    final seed = jsonDecode(
      await rootBundle.loadString(DemoSeed.seedAsset),
    ) as Map<String, dynamic>;
    return [
      for (final photo in (seed['photos'] as List).cast<Map<String, dynamic>>())
        if (_backedUp.contains(photo['backup']) && photo['hidden'] != true)
          photo,
    ];
  }

  static String _name(Map<String, dynamic> photo) =>
      '${DemoSeed.localIdOf(photo).replaceAll(':', '_')}.jpg';

  static int _size(Map<String, dynamic> photo, int base) =>
      base + (photo['id'] as String).codeUnits.fold(0, (a, c) => a + c) * 977;

  static Future<S3ListingResult> list(String path) async {
    S3ListingResult ok(List<String> folders, List<S3Object> objects) =>
        S3ListingResult(
          S3ListingOutcome.ok,
          page: S3ListingPage(folders: folders, objects: objects),
        );
    if (path.isEmpty) return ok([prefix], const []);
    if (path == prefix) {
      return ok(['${prefix}originals/', '${prefix}thumbnails/'], const []);
    }
    if (path == '${prefix}originals/' || path == '${prefix}thumbnails/') {
      final thumbs = path.endsWith('thumbnails/');
      return ok(const [], [
        for (final photo in await _seeded())
          S3Object(
            key: '$path${_name(photo)}',
            size: _size(photo, thumbs ? 14000 : 240000),
            lastModified: DateTime.parse(photo['takenAt'] as String),
          ),
      ]);
    }
    return ok(const [], const []);
  }

  static Future<Uint8List?> bytesOf(String key) async {
    final name = key.substring(key.lastIndexOf('/') + 1);
    for (final photo in await _seeded()) {
      if (_name(photo) != name) continue;
      final scene = photo['scene'] as String;
      final id = photo['id'] as String;
      return Isolate.run(
        () => renderDemoPhoto(
          scene: scene,
          seed: id.codeUnits.fold(7, (h, c) => (h * 31 + c) & 0x7fffffff),
        ),
      );
    }
    return null;
  }
}
