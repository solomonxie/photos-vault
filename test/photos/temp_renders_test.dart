import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/file_hash.dart';
import 'package:photos_vault/photos/temp_renders.dart';

void main() {
  late Directory tmp;
  late Directory renders;

  setUp(() {
    TempRenders.reset();
    tmp = Directory.systemTemp.createTempSync('pv_renders_');
    renders = Directory(p.join(tmp.path, TempRenders.dirName))..createSync();
  });
  tearDown(() {
    TempRenders.reset();
    tmp.deleteSync(recursive: true);
  });

  File render(String name, {Duration age = Duration.zero}) {
    final file = File(p.join(renders.path, '${name}_exif.jpg'))
      ..writeAsBytesSync([1]);
    file.setLastModifiedSync(DateTime.now().subtract(age));
    return file;
  }

  test('the last holder out deletes a render it was told to', () async {
    final file = render('a');
    TempRenders.hold(file.path);
    TempRenders.hold(file.path);

    await TempRenders.release(file.path, delete: true);
    expect(file.existsSync(), isTrue, reason: 'another job still reads it');

    await TempRenders.release(file.path, delete: true);
    expect(file.existsSync(), isFalse);
  });

  test('never touches a file that is not a plugin render', () async {
    final own = File(p.join(tmp.path, 'photo.jpg'))..writeAsBytesSync([1]);
    TempRenders.hold(own.path);
    await TempRenders.release(own.path, delete: true);
    expect(own.existsSync(), isTrue);
  });

  test('the sweep takes old, unheld renders and nothing else', () async {
    final old = render('old', age: const Duration(hours: 2));
    final fresh = render('fresh');
    final held = render('held', age: const Duration(hours: 2));
    final other = File(p.join(renders.path, 'notes.txt'))
      ..writeAsBytesSync([1]);
    other.setLastModifiedSync(DateTime(2020));
    TempRenders.hold(held.path);

    final gone = await TempRenders.sweep(tempDir: tmp.path);

    expect(gone, 1);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(held.existsSync(), isTrue);
    expect(other.existsSync(), isTrue);
  });

  group('PhotoKit resources in tmp/.image (PW3b)', () {
    File resource(String name, {Duration age = Duration.zero}) {
      final dir = Directory(p.join(tmp.path, TempRenders.resourceDirName))
        ..createSync(recursive: true);
      final file = File(p.join(dir.path, name))..writeAsBytesSync([1]);
      file.setLastModifiedSync(DateTime.now().subtract(age));
      return file;
    }

    test('are released and deleted like renders', () async {
      final file = resource('ID_1_o_IMG_1.HEIC');
      TempRenders.hold(file.path);
      await TempRenders.release(file.path, delete: true);
      expect(file.existsSync(), isFalse);
    });

    test('the sweep leaves what a background transfer still reads', () async {
      const hour2 = Duration(hours: 2);
      final sending = resource('ID_1_o_IMG_1.HEIC', age: hour2);
      final done = resource('ID_2_o_IMG_2.HEIC', age: hour2);

      final gone = await TempRenders.sweep(
        tempDir: tmp.path,
        inTransfer: () async => {sending.path},
      );

      expect(gone, 1);
      expect(sending.existsSync(), isTrue);
      expect(done.existsSync(), isFalse);
    });

    test('and sweeps nothing when the transfers cannot be read', () async {
      final old = resource('ID_3_o_IMG_3.HEIC', age: const Duration(hours: 2));
      final render = File(p.join(renders.path, 'x_exif.jpg'))
        ..writeAsBytesSync([1]);
      render.setLastModifiedSync(DateTime(2020));

      expect(
        await TempRenders.sweep(
          tempDir: tmp.path,
          inTransfer: () async => null,
        ),
        0,
      );
      expect(old.existsSync(), isTrue);
      expect(render.existsSync(), isTrue);
    });
  });

  test(
    'hashFile, run in its own isolate, matches the in-memory digest',
    () async {
      final file = File(p.join(tmp.path, 'bytes'))
        ..writeAsBytesSync(List.generate(200000, (i) => i % 251));
      expect(await hashFile(file.path), hashBytes(file.readAsBytesSync()));
      expect(
        await hashBytesApart(file.readAsBytesSync()),
        hashBytes(file.readAsBytesSync()),
      );
    },
  );
}
