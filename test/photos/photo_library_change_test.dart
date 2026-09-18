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
}
