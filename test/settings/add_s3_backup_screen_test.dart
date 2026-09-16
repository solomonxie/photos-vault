import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/settings/add_s3_backup_screen.dart';
import 'package:bring_your_own_photos/settings/backup_targets_store.dart';
import 'package:bring_your_own_photos/settings/s3_backup_target.dart';
import 'package:bring_your_own_photos/settings/s3_connectivity.dart';
import 'package:bring_your_own_photos/settings/s3_region_detection.dart';
import 'package:bring_your_own_photos/settings/s3_target_drafts_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
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
}) async => const S3AccessCheckResult(S3AccessCheckOutcome.ok);

Future<S3RegionDetectionResult> _okRegion(String bucket) async =>
    const S3RegionDetectionResult(
      S3RegionDetectionOutcome.ok,
      region: 'us-east-1',
    );

Future<void> _fillForm(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Access key ID'),
    'AKIA123',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Secret access key'),
    'topsecret',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Bucket'),
    'my-bucket',
  );
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
  await tester.enterText(find.byType(TextField).last, text);
  await tester.pumpAndSettle();
}

void main() {
  _pasteToFillTests();
  _prefixTests();

  testWidgets(
    'shows a validation error when saving with empty required fields',
    (tester) async {
      final store = BackupTargetsStore(store: FakeSecureStore());
      await tester.pumpWidget(
        _wrap(
          AddS3BackupScreen(
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
        AddS3BackupScreen(
          store: store,
          checkAccess: _okAccess,
          detectRegion: _okRegion,
          draftsStore: _fakeDraftsStore(),
        ),
      ),
    );

    expect(find.text(defaultS3Prefix), findsOneWidget);
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
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AddS3BackupScreen(
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
      expect(find.byType(AddS3BackupScreen), findsNothing);
      final saved = await store.loadAll();
      expect(saved, hasLength(1));
      final target = saved.single;
      expect(target.bucket, 'my-bucket');
      expect(target.region, 'eu-west-1');
      expect(target.prefix, defaultS3Prefix);

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
          AddS3BackupScreen(
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
          AddS3BackupScreen(
            store: store,
            detectRegion: _okRegion,
            draftsStore: _fakeDraftsStore(),
            checkAccess:
                ({
                  required accessKeyId,
                  required secretAccessKey,
                  required region,
                  required bucket,
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
      expect(find.byType(AddS3BackupScreen), findsOneWidget);
    },
  );

  testWidgets(
    'a failed save keeps what was typed as a draft, shown on screen',
    (tester) async {
      final store = BackupTargetsStore(store: FakeSecureStore());
      final draftsStore = _fakeDraftsStore();
      await tester.pumpWidget(
        _wrap(
          AddS3BackupScreen(
            store: store,
            detectRegion: _okRegion,
            draftsStore: draftsStore,
            checkAccess:
                ({
                  required accessKeyId,
                  required secretAccessKey,
                  required region,
                  required bucket,
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
      expect(find.text('Drafts', skipOffstage: false), findsOneWidget);
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
        AddS3BackupScreen(
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

    expect(find.widgetWithText(TextFormField, 'AKIA999'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'drafted-bucket'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextFormField, 'p/'), findsOneWidget);
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
        AddS3BackupScreen(
          store: store,
          checkAccess: _okAccess,
          detectRegion: _okRegion,
          draftsStore: draftsStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete draft'));
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
          AddS3BackupScreen(
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

      expect(find.widgetWithText(TextFormField, 'Bucket'), findsOneWidget);

      await tester.tap(find.text('(paste info to add)'));
      await tester.pumpAndSettle();

      // A mode of the same group: the fields are replaced, not pushed down.
      expect(find.widgetWithText(TextFormField, 'Bucket'), findsNothing);
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
      expect(find.widgetWithText(TextFormField, 'AKIAPASTED'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'pasted-bucket'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextFormField, 'pasted/'), findsOneWidget);
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
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Access key ID'),
        'TYPED-BY-HAND',
      );
      await _pasteBlock(tester, 'bucket: pasted-bucket');

      expect(
        find.widgetWithText(TextFormField, 'TYPED-BY-HAND'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextFormField, 'bring-your-own-photos/'),
        findsOneWidget,
        reason: 'no prefix in the block leaves the default alone',
      );
    });

    testWidgets('leaving the box drops the pasted text', (tester) async {
      await pumpForm(tester);
      await tester.tap(find.text('(paste info to add)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'b');
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
        AddS3BackupScreen(
          store: store,
          checkAccess: _okAccess,
          detectRegion: _okRegion,
          draftsStore: _fakeDraftsStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _fillForm(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, defaultS3Prefix),
      '/holiday-snaps',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((await store.loadAll()).single.prefix, 'holiday-snaps/');
  });

  testWidgets('and the field shows what will be saved, not what was typed', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AddS3BackupScreen(
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
    await tester.enterText(
      find.widgetWithText(TextFormField, defaultS3Prefix),
      'holiday-snaps',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextFormField, 'holiday-snaps/'),
      findsOneWidget,
    );
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
