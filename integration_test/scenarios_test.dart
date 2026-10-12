// Run on a simulator against a local S3 stand-in:
//   venv/bin/moto_server -H 127.0.0.1 -p 9443 -c srv.pem -k srv.key
//   flutter test integration_test/scenarios_test.dart -d <sim> \
//     --dart-define=PV_S3_ENDPOINT=localhost:9443
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/asset_removal.dart';
import 'package:photos_vault/photos/library_custody.dart';
import 'package:photos_vault/photos/manual_add.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/upload/original_restore.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/upload/s3_object_delete.dart';
import 'package:photos_vault/upload/signing.dart';
import 'package:photos_vault/viewer/private_album_gate.dart';
import 'package:photos_vault/viewer/private_album_screen.dart';

class _MemoryStore implements SecureStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

const _bucket = 'sim-bucket';
const _prefix = 'photos-vault/';
final _hash = hashPasscode('2580');

late Directory _root;
late AssetRecordStore _store;
late BackupTargetsStore _targets;
late S3BackupTarget _target;
var _n = 0;

/// What the iOS delete prompt was asked about, and how it was answered.
final _promptedFor = <List<String>>[];
var _acceptPrompt = true;

PhotoLibraryService _library() => PhotoLibraryService(
  store: _store,
  deleteAssets: (ids) async {
    _promptedFor.add(ids);
    return _acceptPrompt ? ids : const [];
  },
);

Future<void> _putObject(String key, List<int> bytes) async {
  final url = await presignPutUrl(target: _target, key: key);
  final r = await http.put(url, body: bytes);
  expect(r.statusCode, 200, reason: 'PUT $key');
}

Future<int?> _objectStatus(String key) async =>
    (await http.get(await presignGetUrl(target: _target, key: key))).statusCode;

Uint8List _jpeg({int w = 64, int h = 48, DateTime? taken}) {
  final image = img.Image(width: w, height: h)
    ..clear(img.ColorRgb8(200, 30, 90));
  if (taken != null) {
    final s =
        '${taken.year.toString().padLeft(4, '0')}:${_two(taken.month)}:${_two(taken.day)} '
        '${_two(taken.hour)}:${_two(taken.minute)}:${_two(taken.second)}';
    image.exif.exifIfd['DateTimeOriginal'] = img.IfdValueAscii(s);
  }
  return img.encodeJpg(image);
}

String _two(int v) => v.toString().padLeft(2, '0');

/// A Photos asset with a record pointing at it and its original backed up.
Future<(AssetRecord, Uint8List)> _libraryPhoto({bool backedUp = true}) async {
  final bytes = _jpeg();
  final entity = await PhotoManager.editor.saveImage(
    bytes,
    filename: 'sim_${_n++}.jpg',
  );
  final localId = PhotoLibraryService.localIdFor(entity);
  await _store.upsert(
    localId: localId,
    contentHash: localId,
    platform: 'ios',
    libraryId: entity.id,
    width: 64,
    height: 48,
  );
  if (backedUp) await _backUp(localId, bytes);
  return ((await _store.getByLocalId(localId))!, bytes);
}

Future<String> _backUp(String localId, List<int> bytes) async {
  final key = '${_prefix}originals/sim_${localId.hashCode.abs()}_${_n++}.jpg';
  await _putObject(key, bytes);
  await _store.recordUpload(
    localId: localId,
    kind: DerivativeKind.original,
    targetId: _target.id,
    destinationKey: key,
  );
  await _store.updateDerivative(
    localId,
    DerivativeKind.original,
    DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
  );
  return key;
}

/// A photo that went cloud-only: its Photos asset deleted back then, the
/// record still naming it.
Future<(AssetRecord, Uint8List, String)> _cloudOnly({
  bool inBucket = true,
}) async {
  final bytes = _jpeg(w: 80, h: 60);
  final localId = 'photo:GONE-${_n++}/L0/001';
  await _store.upsert(
    localId: localId,
    contentHash: localId,
    platform: 'ios',
    libraryId: localId.substring(6),
  );
  final key = await _backUp(localId, bytes);
  if (!inBucket) {
    expect(await deleteObject(target: _target, key: key), isTrue);
  }
  await _store.setLocalDeleted(localId, true);
  return ((await _store.getByLocalId(localId))!, bytes, key);
}

late BuildContext _ctx;

Future<void> _app(WidgetTester t, [Widget? home]) async {
  await t.pumpWidget(
    CupertinoApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home:
          home ??
          Builder(
            builder: (c) {
              _ctx = c;
              return const SizedBox();
            },
          ),
    ),
  );
}

Future<void> _until(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue, reason: 'timed out');
}

/// Hides [records] the way the library does, answering the HEIF question
/// with [heif], and waits for the background half to finish.
Future<bool> _hide(
  WidgetTester t,
  List<AssetRecord> records, {
  bool heif = false,
  void Function()? whileRunning,
}) async {
  var settled = false;
  bool? returned;
  unawaited(
    hideIntoPrivateAlbum(
      _ctx,
      assetRecordStore: _store,
      records: records,
      passcodeHash: _hash,
      custody: LibraryCustody(store: _store, library: _library()),
      pendingDeletes: PendingDeletes(store: _store),
      targetsStore: _targets,
      onSettled: () => settled = true,
    ).then((v) => returned = v),
  );
  for (var i = 0; i < 50 && returned == null; i++) {
    await t.pump(const Duration(milliseconds: 100));
    for (final answer in [
      'Download and Hide',
      heif ? 'Convert' : 'Keep Originals',
    ]) {
      final ask = find.text(answer);
      if (ask.evaluate().isNotEmpty) {
        await t.tap(ask);
        await t.pump();
      }
    }
  }
  expect(returned, isNotNull, reason: 'hide returned');
  whileRunning?.call();
  await _until(t, () => settled);
  await t.pump(const Duration(milliseconds: 300));
  return returned!;
}

Future<void> _dismissDialog(WidgetTester t) async {
  final ok = find.text('OK');
  if (ok.evaluate().isNotEmpty) {
    await t.tap(ok);
    await t.pump(const Duration(milliseconds: 300));
  }
}

var _rigReady = false;

/// Fresh store and bucket target per scenario; Photos access and the bucket
/// itself once. Inside the test body: platform calls from `setUpAll` hang
/// under the integration binding.
Future<void> _fresh() async {
  if (!_rigReady) {
    // Granted from outside (`simctl privacy grant`): asking would put up
    // the system sheet, which nothing here can tap.
    var state = PermissionState.notDetermined;
    for (var i = 0; i < 120 && !state.isAuth; i++) {
      state = await PhotoManager.getPermissionState(
        requestOption: const PermissionRequestOption(),
      );
      if (!state.isAuth) await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(state.isAuth, isTrue, reason: 'grant Photos to the app first');
    expect(
      (await http.put(Uri.https('localhost:9443', '/$_bucket'))).statusCode,
      200,
    );
    _rigReady = true;
  }
  _root = await (await getTemporaryDirectory()).createTemp('scenario');
  _store = AssetRecordStore(path: p.join(_root.path, 'v.db'));
  _targets = BackupTargetsStore(store: _MemoryStore());
  _target = await _targets.add(
    accessKeyId: 'sim',
    secretAccessKey: 'sim',
    region: 'us-east-1',
    bucket: _bucket,
    prefix: _prefix,
  );
  _promptedFor.clear();
  _acceptPrompt = true;
}

void _scenario(String name, Future<void> Function(WidgetTester t) body) =>
    testWidgets(name, (t) async {
      await _fresh();
      await body(t);
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Download Full Resolution', () {
    _scenario('brings a cloud-only original back, byte for byte', (t) async {
      final (record, bytes, _) = await _cloudOnly();
      final r = OriginalRestore(targetsStore: _targets, recordStore: _store);
      final path = await r.restore(record);
      expect(path, isNotNull, reason: r.lastProblem);
      expect(await File(path!).readAsBytes(), bytes);
      final after = (await _store.getByLocalId(record.localId))!;
      expect(after.localDeleted, isFalse);
      expect(after.sourcePath, path);
    });

    _scenario(
      'finds it under this bucket\'s prefix when recorded under another',
      (t) async {
        final bytes = _jpeg();
        const localId = 'manual:moved';
        await _store.upsert(
          localId: localId,
          contentHash: 'm',
          platform: 'ios',
        );
        await _putObject('${_prefix}originals/moved.jpg', bytes);
        await _store.updateDerivative(
          localId,
          DerivativeKind.original,
          const DerivativeState(
            status: UploadStatus.uploaded,
            destinationKey: 'old-prefix/originals/moved.jpg',
          ),
        );
        await _store.setLocalDeleted(localId, true);
        final r = OriginalRestore(targetsStore: _targets, recordStore: _store);
        final path = await r.restore((await _store.getByLocalId(localId))!);
        expect(path, isNotNull, reason: r.lastProblem);
      },
    );

    _scenario('says the bucket hasn\'t got it when it hasn\'t', (t) async {
      final (record, _, _) = await _cloudOnly(inBucket: false);
      final r = OriginalRestore(targetsStore: _targets, recordStore: _store);
      expect(await r.restore(record), isNull);
      expect(r.lastProblem, contains('not in $_bucket'));
    });
  });

  group('Hiding', () {
    _scenario('a photo in Photos: gone from the grid at once, then taken '
        'out of Photos and its plain bucket copy queued for deletion', (
      t,
    ) async {
      await _app(t);
      final (record, bytes) = await _libraryPhoto();
      final key = record.stateOf(DerivativeKind.original).destinationKey!;
      var hiddenWhileRunning = false;
      final ok = await _hide(t, [record], whileRunning: () async {});
      hiddenWhileRunning =
          (await _store.getByLocalId(record.localId))!.passcodeHash == _hash;
      expect(ok, isTrue);
      expect(hiddenWhileRunning, isTrue);
      final after = (await _store.getByLocalId(record.localId))!;
      expect(after.passcodeHash, _hash);
      expect(after.libraryId, isNull, reason: 'deleted from Photos');
      expect(_promptedFor.single, [record.libraryId]);
      // Photos rewrites what it stores, so not byte for byte.
      expect(await File(after.sourcePath!).length(), greaterThan(0));
      expect(
        await _store.targetsHolding(record.localId, DerivativeKind.original),
        isEmpty,
      );
      final queued = await PendingDeletes(store: _store).pending();
      expect(queued.map((d) => d.objectKey), contains(key));
      await PendingDeletes(store: _store).drain([_target]);
      expect(await _objectStatus(key), 404, reason: 'plain copy retracted');
    });

    _scenario('a cloud-only photo stays hidden: its original comes down '
        'and nothing tries Photos for it', (t) async {
      await _app(t);
      final (record, bytes, _) = await _cloudOnly();
      expect(await _hide(t, [record]), isTrue);
      final after = (await _store.getByLocalId(record.localId))!;
      expect(after.passcodeHash, _hash, reason: 'must not fall back out');
      expect(after.localDeleted, isFalse);
      expect(await File(after.sourcePath!).readAsBytes(), bytes);
      expect(find.textContaining("wasn't hidden"), findsNothing);
    });

    _scenario('a photo restored earlier whose Photos asset is long gone '
        'hides without a download', (t) async {
      await _app(t);
      final (record, bytes, _) = await _cloudOnly();
      await OriginalRestore(
        targetsStore: _targets,
        recordStore: _store,
      ).restore(record);
      final local = (await _store.getByLocalId(record.localId))!;
      expect(local.localDeleted, isFalse);
      expect(await _hide(t, [local]), isTrue);
      final after = (await _store.getByLocalId(record.localId))!;
      expect(after.passcodeHash, _hash);
      expect(await File(after.sourcePath!).readAsBytes(), bytes);
    });

    _scenario('a shrunk photo: the full original comes down and the '
        'small copy in Photos is what gets deleted', (t) async {
      await _app(t);
      final (record, _) = await _libraryPhoto(backedUp: false);
      final full = _jpeg(w: 400, h: 300);
      await _backUp(record.localId, full);
      await _store.setLocalOptimized(record.localId, true);
      final shrunk = (await _store.getByLocalId(record.localId))!;
      expect(await _hide(t, [shrunk]), isTrue);
      final after = (await _store.getByLocalId(record.localId))!;
      expect(after.passcodeHash, _hash);
      expect(await File(after.sourcePath!).readAsBytes(), full);
      expect(_promptedFor.single, [record.libraryId]);
      expect(after.libraryId, isNull);
    });

    _scenario('a cloud-only photo the bucket lost is refused and stays '
        'in the library, with a message', (t) async {
      await _app(t);
      final (record, _, _) = await _cloudOnly(inBucket: false);
      await _hide(t, [record]);
      final after = (await _store.getByLocalId(record.localId))!;
      expect(after.passcodeHash, isNull);
      expect(after.localDeleted, isTrue);
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      await _dismissDialog(t);
    });

    _scenario('declining the Photos prompt keeps the photo hidden here '
        'and says it is still in Photos', (t) async {
      await _app(t);
      final (record, _) = await _libraryPhoto();
      _acceptPrompt = false;
      await _hide(t, [record]);
      final after = (await _store.getByLocalId(record.localId))!;
      expect(after.passcodeHash, _hash);
      expect(after.libraryId, isNotNull);
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      await _dismissDialog(t);
    });

    _scenario('a mixed batch is one Photos prompt and each lands right', (
      t,
    ) async {
      await _app(t);
      final (a, _) = await _libraryPhoto();
      final (b, _) = await _libraryPhoto();
      final (c, _, _) = await _cloudOnly();
      final (lost, _, _) = await _cloudOnly(inBucket: false);
      await _hide(t, [a, b, c, lost]);
      await _dismissDialog(t);
      final prompts = _promptedFor.where((ids) => ids.contains(a.libraryId));
      expect(prompts.single, containsAll([a.libraryId, b.libraryId]));
      for (final r in [a, b, c]) {
        expect((await _store.getByLocalId(r.localId))!.passcodeHash, _hash);
      }
      expect((await _store.getByLocalId(lost.localId))!.passcodeHash, isNull);
    });

    _scenario('the HEIF question is asked for a JPEG still in Photos', (
      t,
    ) async {
      await _app(t);
      final (record, _) = await _libraryPhoto();
      var asked = false;
      unawaited(
        hideIntoPrivateAlbum(
          _ctx,
          assetRecordStore: _store,
          records: [record],
          passcodeHash: _hash,
          custody: LibraryCustody(store: _store, library: _library()),
          pendingDeletes: PendingDeletes(store: _store),
          targetsStore: _targets,
        ),
      );
      for (var i = 0; i < 30 && !asked; i++) {
        await t.pump(const Duration(milliseconds: 100));
        asked = find.text('Keep Originals').evaluate().isNotEmpty;
      }
      expect(asked, isTrue);
      await t.tap(find.text('Keep Originals'));
      await t.pump(const Duration(seconds: 2));
    });

    _scenario('a hidden photo opens full size in the hidden album', (t) async {
      await _app(t);
      final (record, _, _) = await _cloudOnly();
      await _hide(t, [record]);
      await _app(
        t,
        PrivateAlbumScreen(
          passcodeHash: _hash,
          assetRecordStore: _store,
          targetsStore: _targets,
        ),
      );
      await _until(
        t,
        () => find.byKey(ValueKey(record.localId)).evaluate().isNotEmpty,
      );
      await t.tap(find.byKey(ValueKey(record.localId)));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Download Full Resolution'), findsNothing);
    });
  });

  group('Deleting', () {
    _scenario('a photo Photos still has: binned once the prompt is accepted', (
      t,
    ) async {
      final (record, _) = await _libraryPhoto();
      final removal = AssetRemoval(
        store: _store,
        library: _library(),
        targetsStore: _targets,
      );
      expect(await removal.deleteEverywhere(record), isTrue);
      expect(isInBin((await _store.getByLocalId(record.localId))!), isTrue);
    });

    _scenario('declined: left exactly where it was', (t) async {
      final (record, _) = await _libraryPhoto();
      _acceptPrompt = false;
      final removal = AssetRemoval(
        store: _store,
        library: _library(),
        targetsStore: _targets,
      );
      expect(await removal.deleteEverywhere(record), isFalse);
      expect((await _store.getByLocalId(record.localId))!.isDeleted, isFalse);
    });

    _scenario('one Photos no longer has: binned instead of stuck', (t) async {
      final (record, _, _) = await _cloudOnly();
      await OriginalRestore(
        targetsStore: _targets,
        recordStore: _store,
      ).restore(record);
      _acceptPrompt = false;
      final removal = AssetRemoval(
        store: _store,
        library: _library(),
        targetsStore: _targets,
      );
      final local = (await _store.getByLocalId(record.localId))!;
      expect(await removal.deleteEverywhere(local), isTrue);
      expect(isInBin((await _store.getByLocalId(record.localId))!), isTrue);
    });
  });

  group('Dates', () {
    _scenario('an imported file keeps the date the camera wrote', (t) async {
      final taken = DateTime(2014, 11, 27, 23, 19, 11);
      final file = File(p.join(_root.path, 'import.jpg'))
        ..writeAsBytesSync(_jpeg(taken: taken));
      final record = await ManualAddService(store: _store)
          .enqueueFile(file.path);
      expect(record.createdAt, taken);
    });

    _scenario('a hidden photo given its decoy\'s date gets its own back; '
        'nothing else is touched', (t) async {
      final path = p.join(_root.path, 'undo.db');
      final real = DateTime(2026, 10, 2, 13, 29, 25);
      final decoy = DateTime(2018, 9, 20, 4, 11, 47);
      var store = AssetRecordStore(path: path);
      for (final id in ['manual:hidden', 'manual:plain']) {
        await store.upsert(
          localId: id,
          contentHash: id,
          platform: 'ios',
          sourceType: AssetSourceType.manualFile,
          createdAt: real,
        );
      }
      await store.setPasscodeHash('manual:hidden', _hash);
      await store.close();
      // What the bad build did, through the logging triggers, then a
      // database that hasn't had the undo yet.
      final raw = await sqflite.openDatabase(path);
      await raw.update('asset_record', {
        'created_at': decoy.millisecondsSinceEpoch,
      });
      await raw.delete('app_state', where: "key = 'imports_redate_undone_v1'");
      await raw.close();
      store = AssetRecordStore(path: path);
      expect((await store.getByLocalId('manual:hidden'))!.createdAt, real);
      expect((await store.getByLocalId('manual:plain'))!.createdAt, decoy);
    });
  });
}
