import 'package:photo_manager/photo_manager.dart' show AssetType;
import 'package:photos_vault/photos/photo_changes.dart';
import 'package:photos_vault/photos/photo_library_change.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

MethodCall _change(Object? arguments) => MethodCall('change', arguments);

void main() {
  test('reads the ids out of each bucket', () {
    final change = PhotoLibraryChange.parse(
      _change({
        'create': [
          {'id': 'new-1'},
          {'id': 'new-2'},
        ],
        'update': [
          {'id': 'edited-1'},
        ],
        'delete': [
          {'id': 'gone-1'},
        ],
      }),
    )!;

    expect(change.created, {'new-1', 'new-2'});
    expect(change.updated, {'edited-1'});
    expect(change.deleted, {'gone-1'});
    expect(change.length, 4);
  });

  test('a bucket that is absent is simply empty', () {
    final change = PhotoLibraryChange.parse(
      _change({
        'create': [
          {'id': 'new-1'},
        ],
      }),
    )!;

    expect(change.created, {'new-1'});
    expect(change.updated, isEmpty);
    expect(change.deleted, isEmpty);
  });

  test('a notification about nothing reads as empty', () {
    expect(
      PhotoLibraryChange.parse(_change(<String, Object?>{}))!.isEmpty,
      isTrue,
    );
  });

  group('a malformed payload means "fall back to a scan", never a crash', () {
    test('another method entirely', () {
      expect(PhotoLibraryChange.parse(const MethodCall('something')), isNull);
    });

    test('arguments that are not a map', () {
      expect(PhotoLibraryChange.parse(_change('surprise')), isNull);
      expect(PhotoLibraryChange.parse(_change(null)), isNull);
    });

    test('entries without a usable id are skipped, the rest still read', () {
      final change = PhotoLibraryChange.parse(
        _change({
          'create': [
            {'id': 'good'},
            {'no-id': true},
            'not-a-map',
            {'id': 42},
          ],
          'delete': 'not-a-list',
        }),
      )!;

      expect(change.created, {'good'});
      expect(change.deleted, isEmpty);
    });
  });

  test('a batched asset reads as photo_manager reads the same map', () {
    final entity = PhotoChanges.entityOf({
      'id': 'A/L0/001',
      'createDt': 1700000000,
      'width': 4032,
      'height': 3024,
      'duration': 0,
      'favorite': true,
      'type': 1,
      'modifiedDt': 1700000500,
      'title': '',
      'subtype': 8,
      'lat': 48.85,
      'lng': 2.35,
    })!;
    expect(entity.id, 'A/L0/001');
    expect(entity.type, AssetType.image);
    expect(entity.createDateTime.millisecondsSinceEpoch, 1700000000000);
    expect(entity.modifiedDateTime.millisecondsSinceEpoch, 1700000500000);
    expect(entity.isFavorite, isTrue);
    expect(entity.isLivePhoto, isTrue);
    expect(entity.latLng?.latitude, 48.85);
    expect(entity.latLng?.longitude, 2.35);
    expect(PhotoChanges.entityOf({'width': 1}), isNull);
    expect(PhotoChanges.entityOf({'id': 'x'})!.latLng, isNull);
  });
}
