import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/manual_add.dart';
import 'package:photos_vault/photos/people_zip.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/plain_files.dart';
import 'package:photos_vault/vault/store.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

class _Exclusion extends BackupExclusion {
  @override
  Future<bool> exclude(String path) async => true;
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('pv_people_zip_'));
  tearDown(() => root.deleteSync(recursive: true));

  String zip() {
    final archive = Archive()
      ..add(
        ArchiveFile.bytes(
          'people.csv',
          utf8.encode('name,bio,fields\nMia,Photographer,Phones|+1 555\n'),
        ),
      )
      ..add(ArchiveFile.bytes('photos/Mia/a.jpg', [1, 2, 3]))
      ..add(ArchiveFile.bytes('photos/Mia/b.jpg', [4, 5, 6]))
      ..add(ArchiveFile.bytes('photos/Leo/c.png', [7, 8, 9]))
      ..add(ArchiveFile.bytes('photos/Leo/notes.txt', [0]))
      ..add(ArchiveFile.bytes('readme.md', [0]));
    final path = p.join(root.path, 'people.zip');
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  test('a zip opens as people with their photos and profiles', () async {
    final opened = await PeopleZip.open(zip(), root);
    expect([for (final x in opened.people) x.name], ['Leo', 'Mia']);
    final mia = opened.people.last;
    expect(mia.profile?.bio, 'Photographer');
    expect([for (final f in mia.photos) p.basename(f)], ['a.jpg', 'b.jpg']);
    expect(opened.people.first.profile, isNull);
    expect(opened.skipped, 2);
    await opened.discard();
    expect(opened.dir.existsSync(), isFalse);
  });

  PeopleZipImporter importerOf(
    FakeAssetRecordStore records,
    FakePersonStore people,
  ) => PeopleZipImporter(
    personStore: people,
    recordStore: records,
    tagFor: (code) async => 'tag-$code',
    manualAdd: ManualAddService(
      store: records,
      targetDirectory: () async => root,
    ),
    plainFiles: PlainFiles(
      store: records,
      directory: () async => root,
      exclusion: _Exclusion(),
    ),
  );

  test('visible photos go to Archive and the person; hidden ones to the '
      "person's own hidden folder, tagged to nobody", () async {
    final opened = await PeopleZip.open(zip(), root);
    final records = FakeAssetRecordStore();
    final people = FakePersonStore();
    final importer = importerOf(records, people);
    final picks = [for (final x in opened.people) PeopleZipPick(x)];
    final leo = picks.first..hide = true;
    final mia = picks.last;
    mia.photos.remove(mia.person.photos.last);
    leo.personId = (await people.create(name: 'Leo')).id;

    final profiles = await importer.writeProfiles(picks);
    expect(profiles.created, 1, reason: 'only Mia has a profile row');
    final result = await importer.run(picks, code: '1234');

    expect((result.people, result.visible, result.hidden), (2, 1, 1));
    final byName = {for (final x in await people.listAll()) x.name: x};
    final miaIds = await people.localIdsIn(byName['Mia']!.id);
    expect(miaIds, hasLength(1));
    expect((await records.getByLocalId(miaIds.single))!.isArchived, isTrue);
    expect(await people.localIdsIn(byName['Leo']!.id), isEmpty);
    final hidden = (await records.listAll()).where((r) => r.isHidden).toList();
    expect(hidden, isEmpty, reason: 'born under a code, not the Hidden flag');
    final tagged = (await records.listAll())
        .where((r) => r.passcodeHash != null)
        .single;
    expect(
      tagged.passcodeHash,
      'tag-${personAlbumCode(byName['Leo']!.id, '1234')}',
    );
    expect(leo.include, isTrue);
    expect(
      records.upserts.where((r) => r.passcodeHash == null).single.isArchived,
      isTrue,
      reason: 'archived as written, never a moment in the grid',
    );
  });

  test('photos of somebody not in People load nothing', () async {
    final opened = await PeopleZip.open(zip(), root);
    final records = FakeAssetRecordStore();
    final people = FakePersonStore();
    final picks = [for (final x in opened.people) PeopleZipPick(x)];

    final result = await importerOf(records, people).run(picks);

    expect(result.people, 0);
    expect(await people.listAll(), isEmpty);
    expect(await records.listAll(), isEmpty);
  });

  test('a person left out writes nothing', () async {
    final opened = await PeopleZip.open(zip(), root);
    final records = FakeAssetRecordStore();
    final people = FakePersonStore();
    final picks = [for (final x in opened.people) PeopleZipPick(x)];
    for (final pick in picks) {
      pick.include = false;
    }
    final result = await PeopleZipImporter(
      personStore: people,
      recordStore: records,
      tagFor: (code) async => code,
      manualAdd: ManualAddService(
        store: records,
        targetDirectory: () async => root,
      ),
    ).run(picks);
    expect(result.people, 0);
    expect(await people.listAll(), isEmpty);
    expect(await records.listAll(), isEmpty);
  });

  test("a photo with no camera date takes its person's last seen, not "
      'today', () async {
    final archive = Archive()
      ..add(
        ArchiveFile.bytes(
          'people.csv',
          utf8.encode('name,lastseen\nMia,2009-08-17\n'),
        ),
      )
      ..add(ArchiveFile.bytes('photos/Mia/a.jpg', [1, 2, 3]));
    final path = p.join(root.path, 'dated.zip');
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    final opened = await PeopleZip.open(path, root);
    final records = FakeAssetRecordStore();
    final people = FakePersonStore();
    final importer = importerOf(records, people);
    final picks = [for (final x in opened.people) PeopleZipPick(x)];
    await importer.writeProfiles(picks);

    await importer.run(picks);

    final record = (await records.listAll()).single;
    expect(record.createdAt, DateTime(2009, 8, 17));
    expect(undatedImport(record), isFalse);
  });
}
