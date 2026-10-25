import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/face_file.dart';
import 'package:photos_vault/photos/person.dart' show FaceRect;

void main() {
  test('reads v1 photos and faces, ignoring unknown fields', () {
    final file = FaceFile.parse(
      jsonEncode({
        'version': 1,
        'tool': 'mac',
        'photos': [
          {
            'key': ' 2024-06-01_9f3c ',
            'sha256': 'ABC',
            'extra': true,
            'faces': [
              {
                'box': [0.41, 0.22, 0.12, 0.16],
                'person': 'Alice',
                'score': 0.9,
              },
            ],
          },
        ],
      }),
    );
    final photo = file.photos.single;
    expect(photo.key, '2024-06-01_9f3c');
    expect(photo.sha256, 'abc');
    expect(photo.faces.single.person, 'Alice');
    expect(photo.faces.single.box, const FaceRect(0.41, 0.22, 0.12, 0.16));
    expect(file.unreadable, 0);
  });

  test('drops and counts what cannot be read', () {
    final file = FaceFile.parse(
      jsonEncode({
        'version': 1,
        'photos': [
          'junk',
          {
            'faces': [
              {
                'box': [0, 0, 0.1, 0.1],
                'person': 'NoKey',
              },
            ],
          },
          {
            'key': 'k',
            'faces': [
              {
                'box': [0.1, 0.1, 0.2],
                'person': 'A',
              },
              {
                'box': [0.1, 0.1, 0.2, 0.2],
                'person': ' ',
              },
              {
                'box': [0.1, 0.1, 0, 0.2],
                'person': 'A',
              },
              {
                'box': [0.9, 0.9, 0.3, 0.3],
                'person': 'Edge',
              },
            ],
          },
        ],
      }),
    );
    expect(file.unreadable, 5);
    final face = file.photos.single.faces.single;
    expect(face.person, 'Edge');
    expect(face.box.x, 0.9);
    expect(face.box.width, closeTo(0.1, 1e-9));
  });

  test('rejects anything but version 1 or 2', () {
    expect(
      () => FaceFile.parse('{"version": 3, "photos": []}'),
      throwsFormatException,
    );
    expect(() => FaceFile.parse('[]'), throwsFormatException);
    expect(() => FaceFile.parse('{"version": 1}'), throwsFormatException);
  });

  test('readFaceFile parses bytes off the UI isolate', () async {
    final file = await readFaceFile(
      utf8.encode(
        '{"version":1,"photos":[{"key":"k","faces":'
        '[{"box":[0,0,0.5,0.5],"person":"王小明"}]}]}',
      ),
    );
    expect(file.photos.single.faces.single.person, '王小明');
  });

  group('v2', () {
    test('reads groups, their suggestions, and grouped faces', () {
      final file = FaceFile.parse(
        jsonEncode({
          'version': 2,
          'groups': [
            {'id': 'r1-0007', 'faces': 47},
            {'id': 'r1-S01', 'faces': 691, 'suggest': 'Christine'},
            {'id': 'r1-unused'},
          ],
          'photos': [
            {
              'key': 'k',
              'faces': [
                {
                  'box': [0.1, 0.1, 0.2, 0.2],
                  'person': 'Me',
                },
                {
                  'box': [0.5, 0.1, 0.2, 0.2],
                  'group': 'r1-0007',
                },
                {
                  'box': [0.5, 0.5, 0.2, 0.2],
                  'group': 'r1-S01',
                },
                {
                  'box': [0.7, 0.7, 0.2, 0.2],
                  'group': 'r1-undeclared',
                },
                {
                  'box': [0.1, 0.5, 0.2, 0.2],
                  'person': 'Both',
                  'group': 'r1-0007',
                },
              ],
            },
          ],
        }),
      );
      final faces = file.photos.single.faces;
      expect(faces.map((f) => f.person), ['Me', null, null, null]);
      expect(faces.map((f) => f.group), [
        null,
        'r1-0007',
        'r1-S01',
        'r1-undeclared',
      ]);
      expect(file.unreadable, 1);
      expect(file.groups.keys.toSet(), {'r1-0007', 'r1-S01', 'r1-undeclared'});
      expect(file.groups['r1-S01']!.suggest, 'Christine');
      expect(file.groups['r1-0007']!.suggest, isNull);
    });

    test('v1 knows no groups: a face with only a group is unreadable', () {
      final file = FaceFile.parse(
        jsonEncode({
          'version': 1,
          'photos': [
            {
              'key': 'k',
              'faces': [
                {
                  'box': [0.5, 0.1, 0.2, 0.2],
                  'group': 'g',
                },
                {
                  'box': [0.1, 0.1, 0.2, 0.2],
                  'person': 'Me',
                  'group': 'g',
                },
              ],
            },
          ],
        }),
      );
      expect(file.unreadable, 1);
      expect(file.photos.single.faces.single.person, 'Me');
      expect(file.groups, isEmpty);
    });
  });
}
