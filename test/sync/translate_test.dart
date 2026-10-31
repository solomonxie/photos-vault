import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/sync/op.dart';
import 'package:photos_vault/sync/translate.dart';

Map<String, Object?> _asset({
  String status = 'uploaded',
  bool private = false,
  String description = '',
  String tags = '[]',
}) => {
  'original_status': status,
  'original_key': 'originals/A.HEIC',
  'description': description,
  'tags': tags,
  'is_favorite': 0,
  '_private': private ? 1 : 0,
};

List<String> _ops(List<Change> cs) => [
  for (final c in cs) '${c.o.name} ${c.f ?? ''}'.trim(),
];

void main() {
  test('a photo enters the log only once its original is up, with what it has by then', () {
    expect(
      translate(
        'asset_record',
        'A',
        'insert',
        null,
        _asset(status: 'pending'),
        0,
      ),
      isEmpty,
    );
    expect(
      translate(
        'asset_record',
        'A',
        'update',
        _asset(status: 'pending', description: 'x'),
        _asset(status: 'pending', description: 'y'),
        0,
      ),
      isEmpty,
    );
    final add = translate(
      'asset_record',
      'A',
      'update',
      _asset(status: 'pending'),
      _asset(description: 'Beach', tags: '["sea"]'),
      0,
    );
    expect(_ops(add), ['add', 'madd tags']);
    expect((add.first.x as Map)['description'], 'Beach');
  });

  test('later edits are field sets and tag diffs', () {
    final ops = translate(
      'asset_record',
      'A',
      'update',
      _asset(tags: '["a","b"]'),
      _asset(description: 'New', tags: '["b","c"]'),
      0,
    );
    expect(
      _ops(ops),
      unorderedEquals(['set description', 'madd tags', 'mrem tags']),
    );
  });

  test('hiding sends only `hidden`; a hidden photo says nothing; un-hiding re-sends it whole', () {
    expect(
      [
        for (final c in translate(
          'asset_record',
          'A',
          'update',
          _asset(),
          _asset(private: true),
          0,
        ))
          (c.f, c.x),
      ],
      [('hidden', true)],
    );
    expect(
      translate(
        'asset_record',
        'A',
        'update',
        _asset(private: true),
        _asset(private: true, description: 'secret'),
        0,
      ),
      isEmpty,
    );
    final back = translate(
      'asset_record',
      'A',
      'update',
      _asset(private: true),
      _asset(description: 'open'),
      0,
    );
    expect((back.first.x as Map)['hidden'], false);
    expect(back.first.o, OpKind.add);
  });

  test('a deleted record is purged; never one that was not shared', () {
    expect(_ops(translate('asset_record', 'A', 'delete', _asset(), null, 5)), [
      'set purged',
    ]);
    expect(
      translate(
        'asset_record',
        'A',
        'delete',
        _asset(status: 'pending'),
        null,
        5,
      ),
      isEmpty,
    );
    expect(
      translate('asset_record', 'A', 'delete', _asset(private: true), null, 5),
      isEmpty,
    );
  });

  test('albums: add, rename, delete as a bin; demo albums never', () {
    final row = {
      'name': 'Trip',
      'description': '',
      'cover_local_id': null,
      'tags': '[]',
      'is_demo': 0,
    };
    expect(_ops(translate('album', 'L', 'insert', null, row, 0)), ['add']);
    expect(
      _ops(
        translate('album', 'L', 'update', row, {...row, 'name': 'Lisbon'}, 0),
      ),
      ['set name'],
    );
    expect(_ops(translate('album', 'L', 'delete', row, null, 9)), [
      'set deleted_at',
    ]);
    expect(
      translate('album', 'D', 'insert', null, {...row, 'is_demo': 1}, 0),
      isEmpty,
    );
    expect(_ops(translate('album_asset', 'L/A', 'insert', null, {}, 0)), [
      'madd members',
    ]);
    expect(_ops(translate('person_asset', 'P/A', 'delete', {}, null, 0)), [
      'mrem members',
    ]);
  });
}
