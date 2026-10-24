import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/storage/database_home.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('pv_db_home_'));
  tearDown(() => root.deleteSync(recursive: true));

  File at(String dir, String name) => File(p.join(root.path, dir, name));

  test('databases and their journals move out of Documents', () async {
    for (final name in [
      'photos_vault.db',
      'photos_vault.db-wal',
      'people.db',
      'zz_trace.txt',
      'photos-vault-daily.zip',
    ]) {
      at('docs', name)
        ..createSync(recursive: true)
        ..writeAsStringSync(name);
    }
    at('docs/demo', 'people.db')
      ..createSync(recursive: true)
      ..writeAsStringSync('demo');

    await DatabaseHome.move(
      Directory(p.join(root.path, 'docs')),
      Directory(p.join(root.path, 'support')),
    );

    expect(
      at('support', 'photos_vault.db').readAsStringSync(),
      'photos_vault.db',
    );
    expect(at('support', 'photos_vault.db-wal').existsSync(), isTrue);
    expect(at('support', 'people.db').existsSync(), isTrue);
    expect(at('support/demo', 'people.db').readAsStringSync(), 'demo');
    expect(at('docs', 'photos_vault.db').existsSync(), isFalse);
    expect(at('docs', 'zz_trace.txt').existsSync(), isFalse);
    expect(
      at('docs', 'photos-vault-daily.zip').existsSync(),
      isTrue,
      reason: 'backups stay where the user can take them',
    );
    expect(Directory(p.join(root.path, 'docs', 'demo')).existsSync(), isFalse);
  });

  test('never over a database already moved', () async {
    at('docs', 'people.db')
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    at('support', 'people.db')
      ..createSync(recursive: true)
      ..writeAsStringSync('new');
    await DatabaseHome.move(
      Directory(p.join(root.path, 'docs')),
      Directory(p.join(root.path, 'support')),
    );
    expect(at('support', 'people.db').readAsStringSync(), 'new');
    expect(at('docs', 'people.db').readAsStringSync(), 'old');
  });
}
