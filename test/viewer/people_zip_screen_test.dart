import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/manual_add.dart';
import 'package:photos_vault/photos/people_zip.dart';
import 'package:photos_vault/vault/plain_files.dart';
import 'package:photos_vault/vault/store.dart';
import 'package:photos_vault/viewer/people_zip_screen.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

class _Exclusion extends BackupExclusion {
  @override
  Future<bool> exclude(String path) async => true;
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('pv_zip_screen_'));
  tearDown(() => root.deleteSync(recursive: true));

  String zip(String name, String person, List<int> bytes) {
    final archive = Archive()
      ..add(ArchiveFile.bytes('photos/$person/a.jpg', bytes));
    final path = p.join(root.path, name);
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  testWidgets('several zips picked at once are each loaded, one by one', (
    tester,
  ) async {
    final records = FakeAssetRecordStore();
    final people = FakePersonStore();
    await people.create(name: 'Mia');
    await people.create(name: 'Leo');
    final paths = [
      zip('one.zip', 'Mia', [1, 2, 3]),
      zip('two.zip', 'Leo', [4, 5, 6]),
    ];
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PeopleZipScreen(
          personStore: people,
          assetRecordStore: records,
          pickZips: () async => paths,
          workDir: () async => root,
          importer: PeopleZipImporter(
            personStore: people,
            recordStore: records,
            tagFor: (code) async => code,
            manualAdd: ManualAddService(
              store: records,
              targetDirectory: () async => root,
            ),
            plainFiles: PlainFiles(
              store: records,
              directory: () async => root,
              exclusion: _Exclusion(),
            ),
          ),
        ),
      ),
    );

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    expect(find.textContaining('Zip 1 of 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('peopleZipImport')));
    await settle();
    expect(find.textContaining('Zip 2 of 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('peopleZipImport')));
    await settle();

    expect(find.textContaining('All 2 zips done.'), findsOneWidget);
    final members = await people.allMemberships();
    expect(members.values.where((ids) => ids.isNotEmpty), hasLength(2));
  });

  testWidgets('a zip name like someone here merges into them when chosen', (
    tester,
  ) async {
    final records = FakeAssetRecordStore();
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia Wu');
    final path = zip('one.zip', 'Mia', [1, 2, 3]);
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PeopleZipScreen(
          personStore: people,
          assetRecordStore: records,
          pickZip: () async => path,
          workDir: () async => root,
          importer: PeopleZipImporter(
            personStore: people,
            recordStore: records,
            tagFor: (code) async => code,
            manualAdd: ManualAddService(
              store: records,
              targetDirectory: () async => root,
            ),
            plainFiles: PlainFiles(
              store: records,
              directory: () async => root,
              exclusion: _Exclusion(),
            ),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    expect(find.text('Similar to Mia Wu — tap to choose'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('peopleZipResolve-Mia')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('importMergeInto-0')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('peopleZipImport')));
    await settle();
    expect((await people.allMemberships())[mia.id], hasLength(1));
  });

  testWidgets('a zip profile with a name here merges into them by default', (
    tester,
  ) async {
    final records = FakeAssetRecordStore();
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    final archive = Archive()
      ..add(
        ArchiveFile.bytes('people.csv', 'name,bio\nMia,Painter\n'.codeUnits),
      )
      ..add(ArchiveFile.bytes('photos/Mia/a.jpg', [1, 2, 3]));
    final path = p.join(root.path, 'mia.zip');
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PeopleZipScreen(
          personStore: people,
          assetRecordStore: records,
          pickZip: () async => path,
          workDir: () async => root,
          importer: PeopleZipImporter(
            personStore: people,
            recordStore: records,
            tagFor: (code) async => code,
            manualAdd: ManualAddService(
              store: records,
              targetDirectory: () async => root,
            ),
            plainFiles: PlainFiles(
              store: records,
              directory: () async => root,
              exclusion: _Exclusion(),
            ),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    expect(
      find.text(
        'Merging into the existing person — tap to add as new or change the name',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('peopleZipImportPeople')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('peopleZipImport')));
    await settle();
    expect(await people.listAll(), hasLength(1));
    expect((await people.detailFor(mia.id)).bio, 'Painter');
    expect((await people.allMemberships())[mia.id], hasLength(1));
  });
}
