import 'dart:typed_data';

import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/person_page_screen.dart';
import 'package:photos_vault/viewer/person_profile_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('shows only this person\'s tagged photos', (tester) async {
    final assetStore = FakeAssetRecordStore();
    final personStore = FakePersonStore();
    await assetStore.upsert(
      localId: 'manual:tagged',
      contentHash: 'tagged',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/tagged.jpg',
    );
    await assetStore.upsert(
      localId: 'manual:other',
      contentHash: 'other',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/other.jpg',
    );
    final person = await personStore.create(name: 'Mia');
    await personStore.addAssets(person.id, ['manual:tagged']);

    await tester.pumpWidget(
      _wrap(
        PersonPageScreen(
          person: person,
          personStore: personStore,
          assetRecordStore: assetStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mia'), findsWidgets);
    expect(find.byKey(const ValueKey('manual:tagged')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:other')), findsNothing);
  });

  testWidgets('shows the empty state with nothing tagged', (tester) async {
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonPageScreen(
          person: person,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No photos tagged yet.'), findsOneWidget);
  });

  testWidgets('the whole name line opens the profile, not just the chevron', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final ada = await personStore.create(name: 'Ada');

    await tester.pumpWidget(
      _wrap(
        PersonPageScreen(
          person: ada,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tapped at the far left of the line, well clear of both the chevron
    // and the letters — the gaps in between used to hit nothing.
    final line = tester.getRect(find.byKey(PersonPageScreen.nameLineKey));
    await tester.tapAt(Offset(line.left + 2, line.center.dy));
    await tester.pumpAndSettle();

    expect(find.byType(PersonProfileScreen), findsOneWidget);
  });

  testWidgets('holding a photo opens its menu, profile-photo option and all', (
    tester,
  ) async {
    final assetStore = FakeAssetRecordStore();
    final personStore = FakePersonStore();
    await assetStore.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
    );
    final person = await personStore.create(name: 'Mia');
    await personStore.addAssets(person.id, ['manual:a']);

    await tester.pumpWidget(
      _wrap(
        PersonPageScreen(
          person: person,
          personStore: personStore,
          assetRecordStore: assetStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _hold(tester, find.byKey(const ValueKey('manual:a')));

    expect(find.text('Use as Profile Photo'), findsOneWidget);
    expect(find.text('Remove from Person'), findsOneWidget);
  });

  testWidgets('"Use as Profile Photo" repoints the avatar at that photo', (
    tester,
  ) async {
    final assetStore = FakeAssetRecordStore();
    final personStore = FakePersonStore();
    for (final id in ['manual:first', 'manual:second']) {
      await assetStore.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
      );
    }
    final person = await personStore.create(name: 'Mia');
    await personStore.addAssets(person.id, ['manual:first', 'manual:second']);
    // A face tapped in the first photo — it can't survive onto another one.
    await personStore.update(
      (await personStore.getById(person.id))!
          .copyWith(avatarFace: () => const FaceRect(0.1, 0.1, 0.2, 0.2)),
    );

    await tester.pumpWidget(
      _wrap(
        PersonPageScreen(
          person: (await personStore.getById(person.id))!,
          personStore: personStore,
          assetRecordStore: assetStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _hold(tester, find.byKey(const ValueKey('manual:second')));
    await tester.tap(find.text('Use as Profile Photo'));
    await tester.pumpAndSettle();

    final saved = (await personStore.getById(person.id))!;
    expect(saved.avatarLocalId, 'manual:second');
    // The old photo's face can't survive onto a new photo, and there is
    // no confirmed face in this one to put in its place.
    expect(saved.avatarFace, isNull);
  });

  testWidgets('a profile photo crops to their face, not the whole photo', (
    tester,
  ) async {
    const face = FaceRect(0.4, 0.3, 0.2, 0.2);
    final assetStore = FakeAssetRecordStore();
    await assetStore.upsert(
      localId: 'manual:group',
      contentHash: 'g',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/g.jpg',
    );
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');
    await personStore.addAssets(person.id, ['manual:group']);

    final analyses = FakeAiAnalysisStore();
    await analyses.saveDescriptor(
      localId: 'manual:group',
      face: face,
      personId: person.id,
      descriptor: FaceDescriptor(
        vector: Float32List.fromList(const [1, 0, 0]),
        revision: 1,
      ),
    );

    await tester.pumpWidget(
      _wrap(
        PersonPageScreen(
          person: (await personStore.getById(person.id))!,
          personStore: personStore,
          assetRecordStore: assetStore,
          aiAnalysisStore: analyses,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _hold(tester, find.byKey(const ValueKey('manual:group')));
    await tester.tap(find.text('Use as Profile Photo'));
    await tester.pumpAndSettle();

    // Picking a photo of two people on a beach used to make the beach
    // their portrait.
    final saved = (await personStore.getById(person.id))!;
    expect(saved.avatarLocalId, 'manual:group');
    expect(saved.avatarFace, face);
  });
}

/// A long press that actually opens a [CupertinoContextMenu] — it wants the
/// full 800ms preview animation, which `tester.longPress` is too short for.
Future<void> _hold(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 800));
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}
