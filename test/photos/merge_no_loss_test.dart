import 'dart:typed_data';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/ai_analysis_store.dart';
import 'package:photos_vault/photos/alias_folders.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/vault/hidden_transition.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/passcode_tags.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/memory_bucket.dart';

AlbumKeys _keysFor(String passcode) => AlbumKeys(
  albumKey: Uint8List.fromList(
    List.generate(32, (i) => (i * passcode.hashCode + 7) % 256),
  ),
  entry: PassphraseEntry(
    id: 'entry',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: '',
  ),
);

/// Merging must never lose anything of either person: every kind of
/// record, sealed sets, faces and hidden photos all end up on the kept one.
void main() {
  setUpAll(sqfliteFfiInit);

  PersonStore newStore() {
    final store = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  group('profile data', () {
    test('everything of both lands on the kept person', () async {
      final store = newStore();
      final keep = await store.create(name: 'Mia');
      final gone = await store.create(name: 'Mia Chen');
      final friend = await store.create(name: 'Sam');
      await store.update(gone.copyWith(avatarLocalId: 'g1'));

      await store.addAssets(keep.id, ['k1', 'both']);
      await store.addAssets(gone.id, ['g1', 'g2', 'both']);

      const club = PersonGroup(id: 'c', name: 'Club', kind: GroupKind.circle);
      const team = PersonGroup(id: 't', name: 'Team', kind: GroupKind.circle);
      await store.joinGroup(keep.id, club, scope: PersonScope.open);
      await store.joinGroup(gone.id, club, scope: PersonScope.open);
      await store.joinGroup(gone.id, team, scope: PersonScope.open);

      await store.saveEvent(
        PersonEvent(
          id: 'ev-k',
          personId: keep.id,
          type: PersonEventType.trip,
          at: DateTime(2020),
        ),
        scope: PersonScope.open,
      );
      await store.saveEvent(
        PersonEvent(
          id: 'ev-g',
          personId: gone.id,
          type: PersonEventType.reunion,
          at: DateTime(2001),
        ),
        scope: PersonScope.open,
      );
      await store.addLocation(
        PersonLocation(
          id: 'loc-g',
          personId: gone.id,
          kind: LocationKind.origin,
          place: 'Leeds',
          since: DateTime(1990),
        ),
        scope: PersonScope.open,
      );
      await store.addHistoryEntry(
        PersonHistoryEntry(
          id: 'job-g',
          personId: gone.id,
          category: HistoryCategory.job,
          title: 'Acme',
        ),
        scope: PersonScope.open,
      );
      await store.addHistoryEntry(
        PersonHistoryEntry(
          id: 'edu-k',
          personId: keep.id,
          category: HistoryCategory.education,
          title: 'MIT',
        ),
        scope: PersonScope.open,
      );
      await store.addRelationship(
        gone.id,
        friend.id,
        RelationshipType.friend,
        scope: PersonScope.open,
      );
      // A link between the two would become a link to oneself.
      await store.addRelationship(
        keep.id,
        gone.id,
        RelationshipType.family,
        scope: PersonScope.open,
      );
      await store.saveDetail(
        keep.id,
        PersonDetail(bio: 'Photographer', birthDate: DateTime(1990, 5, 1)),
        scope: PersonScope.open,
      );
      await store.saveDetail(
        gone.id,
        const PersonDetail(bio: 'From Leeds'),
        scope: PersonScope.open,
      );

      expect(await store.merge(keep.id, gone.id), PersonMergeOutcome.merged);

      expect(await store.getById(gone.id), isNull);
      final kept = (await store.getById(keep.id))!;
      expect(kept.name, 'Mia');
      expect(kept.avatarLocalId, 'k1', reason: 'their own picture stays');
      expect((await store.localIdsIn(keep.id)).toSet(), {
        'k1',
        'g1',
        'g2',
        'both',
      });
      expect((await store.groupsFor(keep.id)).map((g) => g.id).toSet(), {
        'c',
        't',
      });
      expect((await store.eventsFor(keep.id)).map((e) => e.id).toSet(), {
        'ev-k',
        'ev-g',
      });
      expect((await store.locationsFor(keep.id)).single.place, 'Leeds');
      expect(
        (await store.historyFor(keep.id, HistoryCategory.job)).single.title,
        'Acme',
      );
      expect(
        (await store.historyFor(
          keep.id,
          HistoryCategory.education,
        )).single.title,
        'MIT',
      );
      final links = await store.relationshipsFor(keep.id);
      expect(links.map((r) => r.relatedPersonId), [friend.id]);
      expect(
        (await store.relationshipsFor(friend.id)).single.relatedPersonId,
        keep.id,
        reason: 'the other side points at the kept person',
      );
      final detail = await store.detailFor(keep.id);
      expect(detail.bio, 'Photographer\n\nFrom Leeds');
      expect(detail.birthDate, DateTime(1990, 5, 1));
      // Nothing left behind under the gone id.
      expect(await store.hasAnyRecord(gone.id), isFalse);
      expect((await store.allMemberships())[gone.id], isNull);
    });

    test('a kept person with no picture takes the gone one\'s', () async {
      final store = newStore();
      final keep = await store.create(name: 'Mia');
      final gone = await store.create(name: 'Mia C');
      await store.addAssets(gone.id, ['g1']);
      await store.merge(keep.id, gone.id);
      expect((await store.getById(keep.id))!.avatarLocalId, 'g1');
    });

    test('sealed sets under a code move over and still open with it', () async {
      final store = newStore();
      final keep = await store.create(name: 'Mia');
      final gone = await store.create(name: 'Mia C');
      final hash = hashPasscode('person-set-1111');
      final keys = _keysFor('1111');
      final sealed = PersonScope.sealed(hash, keys);
      await store.saveDetail(
        gone.id,
        const PersonDetail(bio: 'secret bio'),
        scope: sealed,
      );
      await store.saveEvent(
        PersonEvent(
          id: 'sealed-ev',
          personId: gone.id,
          type: PersonEventType.trip,
          at: DateTime(2015),
        ),
        scope: sealed,
      );

      expect(await store.merge(keep.id, gone.id), PersonMergeOutcome.merged);

      expect(
        (await store.detailFor(keep.id, passcodeHash: hash, keys: keys)).bio,
        'secret bio',
      );
      expect(
        (await store.eventsFor(
          keep.id,
          passcodeHash: hash,
          keys: keys,
        )).single.id,
        'sealed-ev',
      );
      expect((await store.eventsFor(keep.id)), isEmpty, reason: 'still sealed');
    });

    test('both sealed under one code: refused, and nothing changes', () async {
      final store = newStore();
      final keep = await store.create(name: 'Mia');
      final gone = await store.create(name: 'Mia C');
      await store.addAssets(gone.id, ['g1']);
      final hash = hashPasscode('person-set-2222');
      final sealed = PersonScope.sealed(hash, _keysFor('2222'));
      await store.saveDetail(
        keep.id,
        const PersonDetail(bio: 'a'),
        scope: sealed,
      );
      await store.saveDetail(
        gone.id,
        const PersonDetail(bio: 'b'),
        scope: sealed,
      );

      expect(
        await store.merge(keep.id, gone.id),
        PersonMergeOutcome.sealedConflict,
      );

      expect(await store.getById(gone.id), isNotNull);
      expect(await store.localIdsIn(gone.id), ['g1']);
      expect(await store.localIdsIn(keep.id), isEmpty);
      expect(await store.aliasesOf(keep.id), isEmpty);
    });

    test(
      'a person merged with themselves, or with nobody, is untouched',
      () async {
        final store = newStore();
        final mia = await store.create(name: 'Mia');
        await store.addAssets(mia.id, ['p']);
        expect(await store.merge(mia.id, mia.id), PersonMergeOutcome.missing);
        expect(await store.merge(mia.id, 'nobody'), PersonMergeOutcome.missing);
        expect(await store.localIdsIn(mia.id), ['p']);
      },
    );
  });

  test('faces named for the gone person are named for the kept one', () async {
    final faces = AiAnalysisStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(faces.close);
    for (final (id, person) in const [('p1', 'keep'), ('p2', 'gone')]) {
      await faces.nameFaces([
        (localId: id, face: const FaceRect(0.3, 0.3, 0.4, 0.4)),
      ], person);
    }

    await faces.movePerson('gone', 'keep');

    expect(await faces.facesOfPerson('gone'), isEmpty);
    expect(await faces.facesOfPerson('keep'), hasLength(2));
  });

  group('hidden folders', () {
    late FakeAssetRecordStore records;
    late VaultKeys keys;
    late Directory dir;

    Future<String> tagOf(String personId, String digits) => PasscodeTags(
      records: records,
      vaultKeys: keys,
    ).tagFor(personAlbumCode(personId, digits));

    Future<File> hidden(String id, String tag) async {
      final file = File('${dir.path}/$id.jpg')..writeAsBytesSync([1, 2, 3]);
      await records.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: file.path,
      );
      await records.setPasscodeHash(id, tag);
      return file;
    }

    AliasFolders folders() => AliasFolders(
      store: records,
      vaultKeys: keys,
      transition: HiddenTransition(
        store: records,
        loadTargets: () async => const [],
        pendingDeletes: PendingDeletes(store: records, ops: MemoryBucket()),
        analysisStore: FakeAiAnalysisStore(),
        thumbnails: ThumbnailCache(store: records),
      ),
    );

    setUp(() async {
      records = FakeAssetRecordStore();
      keys = VaultKeys(store: FakeSecureStore(), derive: deriveOnThisIsolate);
      await keys.add('a good long passphrase');
      dir = Directory.systemTemp.createTempSync('pv_merge_hidden_');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('the merge itself touches no hidden photo', () async {
      final store = newStore();
      final keep = await store.create(name: 'Mia');
      final gone = await store.create(name: 'Mia C');
      final goneTag = await tagOf(gone.id, '1111');
      final file = await hidden('h1', goneTag);

      await store.merge(keep.id, gone.id);

      final record = (await records.getByLocalId('h1'))!;
      expect(record.passcodeHash, goneTag);
      expect(file.existsSync(), isTrue);
      expect(await store.aliasesOf(keep.id), [gone.id]);
    });

    test('several merged, each with their own code: every photo opens on '
        'the kept person with the digits it was hidden under', () async {
      final store = newStore();
      final keep = await store.create(name: 'Mia');
      final a = await store.create(name: 'Mia A');
      final b = await store.create(name: 'Mia B');
      final keepTag1111 = await tagOf(keep.id, '1111');
      await hidden('own', keepTag1111);
      final fa = await hidden('a1', await tagOf(a.id, '1111'));
      final fb = await hidden('b1', await tagOf(b.id, '2222'));

      await store.merge(keep.id, a.id);
      await store.merge(keep.id, b.id);
      final aliases = await store.aliasesOf(keep.id);
      expect(aliases, [a.id, b.id]);

      // Same digits as the kept person's own: one folder.
      expect(await folders().fold(keep.id, aliases, '1111'), isEmpty);
      expect(
        (await records.forPasscodeHash(keepTag1111)).map((r) => r.localId),
        {'own', 'a1'},
      );
      // B's under 2222 untouched until 2222 is typed.
      expect(
        (await records.getByLocalId('b1'))!.passcodeHash,
        await tagOf(b.id, '2222'),
      );

      expect(await folders().fold(keep.id, aliases, '2222'), isEmpty);
      expect(
        (await records.forPasscodeHash(await tagOf(keep.id, '2222')))
            .single
            .localId,
        'b1',
      );
      for (final f in [fa, fb]) {
        expect(f.existsSync(), isTrue);
      }
      expect(
        (await records.listAll()).where((r) => r.passcodeHash == null),
        isEmpty,
        reason: 'nothing came out of hiding',
      );
    });

    test('a chain of merges keeps the oldest folder reachable', () async {
      final store = newStore();
      final a = await store.create(name: 'A');
      final b = await store.create(name: 'B');
      final c = await store.create(name: 'C');
      await hidden('c1', await tagOf(c.id, '3333'));

      await store.merge(b.id, c.id);
      await store.merge(a.id, b.id);

      expect(
        await folders().fold(a.id, await store.aliasesOf(a.id), '3333'),
        isEmpty,
      );
      expect(
        (await records.getByLocalId('c1'))!.passcodeHash,
        await tagOf(a.id, '3333'),
      );
    });
  });
}
