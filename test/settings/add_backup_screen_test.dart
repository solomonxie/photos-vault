import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/settings/add_backup_screen.dart';
import 'package:bring_your_own_photos/settings/backup_storage_type.dart';
import 'package:bring_your_own_photos/settings/backup_targets_store.dart';
import 'package:bring_your_own_photos/settings/s3_backup_target.dart';
import 'package:bring_your_own_photos/settings/s3_connectivity.dart';
import 'package:bring_your_own_photos/settings/s3_region_detection.dart';
import 'package:bring_your_own_photos/settings/s3_target_drafts_store.dart';
import 'package:bring_your_own_photos/viewer/search_picker_sheet.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';

Widget _wrap(Widget child) {
  return CupertinoApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

S3TargetDraftsStore _fakeDraftsStore() =>
    S3TargetDraftsStore(store: FakeSecureStore());

Future<S3AccessCheckResult> _okAccess({
  required String accessKeyId,
  required String secretAccessKey,
  required String region,
  required String bucket,
  BackupStorageType provider = BackupStorageType.s3,
}) async => const S3AccessCheckResult(S3AccessCheckOutcome.ok);

Future<S3RegionDetectionResult> _okRegion(String bucket) async =>
    const S3RegionDetectionResult(
      S3RegionDetectionOutcome.ok,
      region: 'us-east-1',
    );

Future<void> _fillForm(WidgetTester tester) async {
  await tester.enterText(find.byKey(accessKeyIdFieldKey), 'AKIA123');
  await tester.enterText(find.byKey(secretAccessKeyFieldKey), 'topsecret');
  await tester.enterText(find.byKey(bucketFieldKey), 'my-bucket');
}

/// The drafts list sits under the whole form; a taller surface keeps it and
/// the fields it fills on screen at the same time.
void _tallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// What a paste looks like to the field: the whole block arriving as one
/// multi-character insert.
Future<void> _pasteBlock(WidgetTester tester, String text) async {
  await tester.tap(find.text('(paste info to add)'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(pasteFieldKey), text);
  await tester.pumpAndSettle();
}

void main() {
  _pasteToFillTests();
  _prefixTests();
  _providerTests();

  testWidgets(
    'shows a validation error when saving with empty required fields',
    (tester) async {
      final store = BackupTargetsStore(store: FakeSecureStore());
      await tester.pumpWidget(
        _wrap(
          AddBackupScreen(
            store: store,
            checkAccess: _okAccess,
            detectRegion: _okRegion,
            draftsStore: _fakeDraftsStore(),
          ),
        ),
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Required'), findsWidgets);
    },
  );

  testWidgets('prefills the key prefix with a sensible default', (
    tester,
  ) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddBackupScreen(
          store: store,
          checkAccess: _okAccess,
          detectRegion: _okRegion,
          draftsStore: _fakeDraftsStore(),
        ),
      ),
    );

    expect(find.text(defaultKeyPrefix), findsOneWidget);
  });

  testWidgets(
    'detects the region from the bucket name, then validates access, then saves',
    (tester) async {
      final store = BackupTargetsStore(store: FakeSecureStore());
      final draftsStore = _fakeDraftsStore();
      var checkedRegion = '';
      var detectedForBucket = '';
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => CupertinoButton(
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute(
                  builder: (_) => AddBackupScreen(
                    store: store,
                    draftsStore: draftsStore,
                    detectRegion: (bucket) async {
                      detectedForBucket = bucket;
                      return const S3RegionDetectionResult(
                        S3RegionDetectionOutcome.ok,
                        region: 'eu-west-1',
                      );
                    },
                    checkAccess:
                        ({
                          required accessKeyId,
                          required secretAccessKey,
                          required region,
                          required bucket,
                          provider = BackupStorageType.s3,
                        }) async {
                          checkedRegion = region;
                          return const S3AccessCheckResult(
                            S3AccessCheckOutcome.ok,
                          );
                        },
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await _fillForm(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(detectedForBucket, 'my-bucket');
      expect(checkedRegion, 'eu-west-1');
      expect(find.byType(AddBackupScreen), findsNothing);
      final saved = await store.loadAll();
      expect(saved, hasLength(1));
      final target = saved.single;
      expect(target.bucket, 'my-bucket');
      expect(target.region, 'eu-west-1');
      expect(target.prefix, defaultKeyPrefix);

      // The draft from this attempt graduated into a real target, so it
      // shouldn't also linger in the draft list.
      expect(await draftsStore.loadAll(), isEmpty);
    },
  );

  testWidgets(
    'shows an inline error and does not save when region detection fails',
    (tester) async {
      final store = BackupTargetsStore(store: FakeSecureStore());
      await tester.pumpWidget(
        _wrap(
          AddBackupScreen(
            store: store,
            checkAccess: _okAccess,
            detectRegion: (bucket) async => const S3RegionDetectionResult(
              S3RegionDetectionOutcome.networkError,
            ),
            draftsStore: _fakeDraftsStore(),
          ),
        ),
      );

      await _fillForm(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't detect"), findsOneWidget);
      expect(await store.loadAll(), isEmpty);
    },
  );

  testWidgets(
    'shows an inline error and does not save when access is forbidden',
    (tester) async {
      final store = BackupTargetsStore(store: FakeSecureStore());
      await tester.pumpWidget(
        _wrap(
          AddBackupScreen(
            store: store,
            detectRegion: _okRegion,
            draftsStore: _fakeDraftsStore(),
            checkAccess:
                ({
                  required accessKeyId,
                  required secretAccessKey,
                  required region,
                  required bucket,
                  provider = BackupStorageType.s3,
                }) async =>
                    const S3AccessCheckResult(S3AccessCheckOutcome.forbidden),
          ),
        ),
      );

      await _fillForm(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Access denied'), findsOneWidget);
      expect(await store.loadAll(), isEmpty);
      // Screen stays open so the user can fix and retry.
      expect(find.byType(AddBackupScreen), findsOneWidget);
    },
  );

  testWidgets(
    'a failed save keeps what was typed as a draft, shown on screen',
    (tester) async {
      final store = BackupTargetsStore(store: FakeSecureStore());
      final draftsStore = _fakeDraftsStore();
      await tester.pumpWidget(
        _wrap(
          AddBackupScreen(
            store: store,
            detectRegion: _okRegion,
            draftsStore: draftsStore,
            checkAccess:
                ({
                  required accessKeyId,
                  required secretAccessKey,
                  required region,
                  required bucket,
                  provider = BackupStorageType.s3,
                }) async =>
                    const S3AccessCheckResult(S3AccessCheckOutcome.forbidden),
          ),
        ),
      );

      await _fillForm(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final drafts = await draftsStore.loadAll();
      expect(drafts, hasLength(1));
      expect(drafts.single.bucket, 'my-bucket');
      // Below the fold once the storage-type picker and length-hint text make
      // the form taller, hence skipOffstage: false.
      expect(find.text('DRAFTS', skipOffstage: false), findsOneWidget);
      expect(find.text('my-bucket', skipOffstage: false), findsNWidgets(2));
    },
  );

  testWidgets('tapping a draft fills the form from it', (tester) async {
    _tallSurface(tester);
    final store = BackupTargetsStore(store: FakeSecureStore());
    final draftsStore = _fakeDraftsStore();
    await draftsStore.save(
      accessKeyId: 'AKIA999',
      secretAccessKey: 'old-secret',
      bucket: 'drafted-bucket',
      prefix: 'p/',
    );

    await tester.pumpWidget(
      _wrap(
        AddBackupScreen(
          store: store,
          checkAccess: _okAccess,
          detectRegion: _okRegion,
          draftsStore: draftsStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('drafted-bucket'));
    await tester.pumpAndSettle();

    expect(find.text('AKIA999'), findsOneWidget);
    // Once in the field, once as the draft row it was filled from.
    expect(find.text('drafted-bucket'), findsNWidgets(2));
    expect(find.text('p/'), findsOneWidget);
  });

  testWidgets('deleting a draft removes it from the list', (tester) async {
    _tallSurface(tester);
    final store = BackupTargetsStore(store: FakeSecureStore());
    final draftsStore = _fakeDraftsStore();
    await draftsStore.save(
      accessKeyId: 'AKIA999',
      secretAccessKey: 'old-secret',
      bucket: 'drafted-bucket',
      prefix: '',
    );

    await tester.pumpWidget(
      _wrap(
        AddBackupScreen(
          store: store,
          checkAccess: _okAccess,
          detectRegion: _okRegion,
          draftsStore: draftsStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.xmark));
    await tester.pumpAndSettle();

    expect(find.text('drafted-bucket'), findsNothing);
    expect(await draftsStore.loadAll(), isEmpty);
  });
}

void _pasteToFillTests() {
  group('paste to fill', () {
    Future<void> pumpForm(WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          AddBackupScreen(
            store: BackupTargetsStore(store: FakeSecureStore()),
            checkAccess: _okAccess,
            detectRegion: _okRegion,
            draftsStore: _fakeDraftsStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the fields are the form until the header button is tapped', (
      tester,
    ) async {
      await pumpForm(tester);

      expect(find.byKey(bucketFieldKey), findsOneWidget);

      await tester.tap(find.text('(paste info to add)'));
      await tester.pumpAndSettle();

      // A mode of the same group: the fields are replaced, not pushed down.
      expect(find.byKey(bucketFieldKey), findsNothing);
      expect(find.text('(back to fields)'), findsOneWidget);
    });

    testWidgets('one paste fills every named field and snaps back', (
      tester,
    ) async {
      await pumpForm(tester);
      await _pasteBlock(tester, '''
bucket: pasted-bucket
prefix: pasted/
access_key_id: AKIAPASTED
secret_access_key: pasted-secret
''');

      // Back on the fields, which are the confirmation.
      expect(find.text('(paste info to add)'), findsOneWidget);
      expect(find.text('AKIAPASTED'), findsOneWidget);
      expect(find.text('pasted-bucket'), findsOneWidget);
      expect(find.text('pasted/'), findsOneWidget);
    });

    testWidgets('a block that names no field leaves the box open', (
      tester,
    ) async {
      await pumpForm(tester);
      await _pasteBlock(tester, 'just some notes I had copied');

      expect(find.text('(back to fields)'), findsOneWidget);
    });

    testWidgets('what the block leaves out keeps what was typed by hand', (
      tester,
    ) async {
      await pumpForm(tester);
      await tester.enterText(find.byKey(accessKeyIdFieldKey), 'TYPED-BY-HAND');
      await _pasteBlock(tester, 'bucket: pasted-bucket');

      expect(find.text('TYPED-BY-HAND'), findsOneWidget);
      expect(
        find.text('bring-your-own-photos/'),
        findsOneWidget,
        reason: 'no prefix in the block leaves the default alone',
      );
    });

    testWidgets('leaving the box drops the pasted text', (tester) async {
      await pumpForm(tester);
      await tester.tap(find.text('(paste info to add)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(pasteFieldKey), 'b');
      await tester.pumpAndSettle();

      await tester.tap(find.text('(back to fields)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('(paste info to add)'));
      await tester.pumpAndSettle();

      expect(find.text('b'), findsNothing);
    });
  });
}

void _prefixTests() {
  testWidgets('a prefix typed without a trailing slash gets one on save', (
    tester,
  ) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddBackupScreen(
          store: store,
          checkAccess: _okAccess,
          detectRegion: _okRegion,
          draftsStore: _fakeDraftsStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _fillForm(tester);
    await tester.enterText(find.byKey(prefixFieldKey), '/holiday-snaps');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((await store.loadAll()).single.prefix, 'holiday-snaps/');
  });

  testWidgets('and the field shows what will be saved, not what was typed', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AddBackupScreen(
          store: BackupTargetsStore(store: FakeSecureStore()),
          checkAccess: _okAccess,
          // Fails, so the form stays open and its fields can be read back.
          detectRegion: (bucket) async => const S3RegionDetectionResult(
            S3RegionDetectionOutcome.networkError,
          ),
          draftsStore: _fakeDraftsStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _fillForm(tester);
    await tester.enterText(find.byKey(prefixFieldKey), 'holiday-snaps');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('holiday-snaps/'), findsOneWidget);
  });

  group('key prefix', () {
    test('names a folder, so it ends in a slash', () {
      expect(normalizeKeyPrefix('photos'), 'photos/');
      expect(normalizeKeyPrefix('photos/'), 'photos/');
      expect(normalizeKeyPrefix('a/b/c'), 'a/b/c/');
    });

    test('never starts with one', () {
      expect(normalizeKeyPrefix('/photos'), 'photos/');
      expect(normalizeKeyPrefix('//photos/'), 'photos/');
    });

    test('an empty prefix stays empty — the bucket root is a folder too', () {
      expect(normalizeKeyPrefix(''), '');
      expect(normalizeKeyPrefix('   '), '');
      expect(normalizeKeyPrefix('/'), '');
    });

    test('surrounding whitespace from a paste goes', () {
      expect(normalizeKeyPrefix('  photos  '), 'photos/');
    });
  });
}

Future<void> _pickProvider(WidgetTester tester, String name) async {
  await tester.tap(find.text('Storage type'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

/// The region sheet is the app's search-or-create picker: type to filter,
/// tap the match.
Future<void> _pickRegion(WidgetTester tester, String region) async {
  await tester.tap(find.byKey(regionFieldKey));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(searchPickerFieldKey), region);
  await tester.pumpAndSettle();
  await tester.tap(find.text(region).last);
  await tester.pumpAndSettle();
}

void _providerTests() {
  group('other providers', () {
    testWidgets('picking COS asks for a region and renames the key fields', (
      tester,
    ) async {
      _tallSurface(tester);
      await tester.pumpWidget(
        _wrap(
          AddBackupScreen(
            store: BackupTargetsStore(store: FakeSecureStore()),
            checkAccess: _okAccess,
            detectRegion: _okRegion,
            draftsStore: _fakeDraftsStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(regionFieldKey), findsNothing);

      await _pickProvider(tester, 'Tencent Cloud COS');

      expect(find.byKey(regionFieldKey), findsOneWidget);
      expect(find.text('SecretId'), findsOneWidget);
      expect(find.text('SecretKey'), findsOneWidget);
      expect(find.text('Access key ID'), findsNothing);
    });

    testWidgets('a COS target saves with its picked region, undetected', (
      tester,
    ) async {
      _tallSurface(tester);
      final store = BackupTargetsStore(store: FakeSecureStore());
      var detected = false;
      var checkedProvider = BackupStorageType.s3;
      await tester.pumpWidget(
        _wrap(
          AddBackupScreen(
            store: store,
            draftsStore: _fakeDraftsStore(),
            detectRegion: (bucket) async {
              detected = true;
              return const S3RegionDetectionResult(
                S3RegionDetectionOutcome.networkError,
              );
            },
            checkAccess:
                ({
                  required accessKeyId,
                  required secretAccessKey,
                  required region,
                  required bucket,
                  provider = BackupStorageType.s3,
                }) async {
                  checkedProvider = provider;
                  return const S3AccessCheckResult(S3AccessCheckOutcome.ok);
                },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _pickProvider(tester, 'Tencent Cloud COS');
      await tester.enterText(find.byKey(accessKeyIdFieldKey), 'AKIDexample');
      await tester.enterText(find.byKey(secretAccessKeyFieldKey), 'shh');
      await tester.enterText(
        find.byKey(bucketFieldKey),
        'my-photos-1250000000',
      );
      await _pickRegion(tester, 'ap-guangzhou');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // S3's bucket-name trick means nothing to COS, so it isn't tried.
      expect(detected, isFalse);
      expect(checkedProvider, BackupStorageType.tencentCos);
      final saved = (await store.loadAll()).single;
      expect(saved.provider, BackupStorageType.tencentCos);
      expect(saved.region, 'ap-guangzhou');
      expect(saved.bucket, 'my-photos-1250000000');
    });

    testWidgets('saving without a region says so instead of failing later', (
      tester,
    ) async {
      _tallSurface(tester);
      final store = BackupTargetsStore(store: FakeSecureStore());
      await tester.pumpWidget(
        _wrap(
          AddBackupScreen(
            store: store,
            checkAccess: _okAccess,
            detectRegion: _okRegion,
            draftsStore: _fakeDraftsStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _pickProvider(tester, 'Alibaba Cloud OSS');
      await tester.enterText(find.byKey(accessKeyIdFieldKey), 'LTAIexample');
      await tester.enterText(find.byKey(secretAccessKeyFieldKey), 'shh');
      await tester.enterText(find.byKey(bucketFieldKey), 'my-photos');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Pick the region'), findsOneWidget);
      expect(await store.loadAll(), isEmpty);
    });

    testWidgets('a pasted endpoint switches provider and fills the region', (
      tester,
    ) async {
      _tallSurface(tester);
      await tester.pumpWidget(
        _wrap(
          AddBackupScreen(
            store: BackupTargetsStore(store: FakeSecureStore()),
            checkAccess: _okAccess,
            detectRegion: _okRegion,
            draftsStore: _fakeDraftsStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _pasteBlock(tester, '''
https://holiday-snaps-1250000000.cos.ap-shanghai.myqcloud.com
SecretId: AKIDexample
SecretKey: shh
''');

      expect(find.text('holiday-snaps-1250000000'), findsOneWidget);
      expect(find.text('AKIDexample'), findsOneWidget);
      expect(find.text('ap-shanghai'), findsOneWidget);
    });
  });
}
