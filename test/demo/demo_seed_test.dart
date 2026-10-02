import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/demo/demo_images.dart';
import 'package:photos_vault/photos/image_pipeline.dart';

void main() {
  final seed = jsonDecode(
    File('demo/seed.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final photos = (seed['photos'] as List).cast<Map<String, dynamic>>();

  test('every seeded photo draws as a real JPEG', () {
    for (final scene in {for (final p in photos) p['scene'] as String}) {
      final bytes = renderDemoPhoto(
        scene: scene,
        seed: 1,
        width: 96,
        height: 72,
      );
      final image = decodePhoto(bytes);
      expect(image?.width, 96, reason: scene);
    }
  });

  test('the seed exercises every feature it is meant to show', () {
    final backups = {for (final p in photos) p['backup']};
    expect(backups, containsAll(['uploaded', 'cloudOnly', 'pending']));
    expect(photos.where((p) => p['hidden'] == true), isNotEmpty);
    expect(
      photos.where(
        (p) =>
            (p['addedDaysAgo'] as int) < 7 &&
            DateTime.parse(p['takenAt'] as String).year < 2026,
      ),
      isNotEmpty,
      reason: 'an old photo imported recently, for Recently Added',
    );
    expect((seed['hiddenAlbum'] as Map)['notes'], isNotEmpty);
  });
}
