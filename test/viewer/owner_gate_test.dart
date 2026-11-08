import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/person_owner.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/settings_screen.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/passcode_tags.dart';
import 'package:photos_vault/viewer/owner_gate.dart';
import 'package:photos_vault/viewer/private_album_gate.dart';
import 'package:photos_vault/viewer/private_album_screen.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Widget _button(String label, Future<void> Function(BuildContext) onTap) =>
    _wrap(
      Builder(
        builder: (context) => Center(
          child: CupertinoButton(
            onPressed: () => onTap(context),
            child: Text(label),
          ),
        ),
      ),
    );

void main() {
  late FakeAssetRecordStore assets;
  late FakePersonStore people;

  setUp(() async {
    assets = FakeAssetRecordStore();
    people = FakePersonStore();
    await people.create(name: 'Kim', id: 'kim');
    await people.create(name: 'Lee', id: 'lee');
  });

  Future<void> tapOpen(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('no owner yet: who you are is asked, then kept', (tester) async {
    String? picked = 'unset';
    await tester.pumpWidget(
      _button(
        'open',
        (context) async =>
            picked = await ensureOwner(context, store: assets, people: people),
      ),
    );
    final markBefore = assets.mark;

    await tapOpen(tester);
    expect(find.text('Who Are You?'), findsOneWidget);
    await tester.tap(find.text('Lee'));
    await tester.pumpAndSettle();

    expect(picked, 'lee');
    expect(await PersonOwner(assets).id(), 'lee');
    // A change the backup carries moves its mark.
    expect(assets.mark, greaterThan(markBefore));

    // Asked once: the next time it is simply known.
    picked = null;
    await tapOpen(tester);
    expect(find.text('Who Are You?'), findsNothing);
    expect(picked, 'lee');
  });

  testWidgets('an owner since deleted is asked about again', (tester) async {
    await PersonOwner(assets).set('gone');
    await tester.pumpWidget(
      _button(
        'open',
        (context) => ensureOwner(context, store: assets, people: people),
      ),
    );

    await tapOpen(tester);

    expect(find.text('Who Are You?'), findsOneWidget);
  });

  testWidgets("main-page Hidden asks who you are before the keypad, and "
      "dismissing it opens nothing", (tester) async {
    final keys = VaultKeys(
      store: FakeSecureStore(),
      derive: deriveOnThisIsolate,
    );
    await keys.add('a good long passphrase');
    await tester.pumpWidget(
      _button(
        'open',
        (context) => openOwnerHidden(
          context,
          assetRecordStore: assets,
          personStore: people,
          vaultKeys: keys,
        ),
      ),
    );

    await tapOpen(tester);
    expect(find.text('Who Are You?'), findsOneWidget);
    expect(find.text('0'), findsNothing);

    // Dismissed: no keypad, nobody set.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('0'), findsNothing);
    expect(await PersonOwner(assets).id(), isNull);

    await tapOpen(tester);
    await tester.tap(find.text('Kim'));
    await tester.pumpAndSettle();

    expect(await PersonOwner(assets).id(), 'kim');
    // The keypad, for the owner's folder.
    expect(find.text('0'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  group('unlocking the owner folder', () {
    late VaultKeys keys;

    setUp(() async {
      keys = VaultKeys(store: FakeSecureStore(), derive: deriveOnThisIsolate);
      await keys.add('a good long passphrase');
      await PersonOwner(assets).set('kim');
    });

    Future<void> unlock(
      WidgetTester tester,
      Future<int> Function(String tag, AlbumKeys? keys) count, {
      LeftoverCarrier? carry,
    }) async {
      await tester.pumpWidget(
        _button(
          'open',
          (context) => openOwnerHidden(
            context,
            assetRecordStore: assets,
            personStore: people,
            vaultKeys: keys,
            countLeftover: count,
            carryLeftover: carry ?? (_, _, _) async => 0,
          ),
        ),
      );
      await tapOpen(tester);
      for (final d in '1234'.split('')) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    Future<String> tagOf(String code) =>
        PasscodeTags(records: assets, vaultKeys: keys).tagFor(code);

    testWidgets('only superseded copies left: no row, and back goes '
        'straight out', (tester) async {
      final asked = <String>[];
      await unlock(tester, (tag, _) async {
        asked.add(tag);
        return 0;
      });

      expect(find.byType(PrivateAlbumScreen), findsOneWidget);
      // The bare digits were asked about, and hold nothing of their own.
      expect(asked, [await tagOf('1234')]);
      expect(find.byKey(const ValueKey('hiddenLeftover0')), findsNothing);

      await tester.tap(find.byType(CupertinoNavigationBarBackButton));
      await tester.pumpAndSettle();
      expect(find.byType(PrivateAlbumScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('photos only the bucket has are carried in the background '
        'and the row goes once nothing is left', (tester) async {
      final plainTag = await tagOf('1234');
      final ownerTag = await tagOf(personAlbumCode('kim', '1234'));
      var bucketOnly = 2;
      final carried = <(String, String)>[];
      final done = Completer<void>();
      await unlock(
        tester,
        (tag, _) async => tag == plainTag ? bucketOnly : 0,
        carry: (from, _, to) async {
          carried.add((from, to));
          await done.future;
          bucketOnly = 0;
          return 2;
        },
      );

      // Shown while the carry runs.
      final row = find.byKey(const ValueKey('hiddenLeftover0'));
      await tester.scrollUntilVisible(row, 200);
      expect(find.text('Older photos · 2'), findsOneWidget);
      expect(carried, [(plainTag, ownerTag)]);

      done.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('hiddenLeftover0')), findsNothing);
      // Once per open screen: the recount doesn't start another.
      expect(carried, hasLength(1));
    });

    testWidgets('real leftovers: one row that opens them, and back returns '
        'to the owner folder, then out', (tester) async {
      final plainTag = await tagOf('1234');
      await unlock(tester, (tag, _) async => tag == plainTag ? 3 : 0);

      final row = find.byKey(const ValueKey('hiddenLeftover0'));
      await tester.scrollUntilVisible(row, 200);
      expect(find.text('Older photos · 3'), findsOneWidget);
      expect(find.byType(PrivateAlbumScreen), findsOneWidget);

      await tester.tap(row);
      await tester.pumpAndSettle();
      final screens = tester
          .widgetList<PrivateAlbumScreen>(find.byType(PrivateAlbumScreen))
          .toList();
      expect(screens.last.passcodeHash, plainTag);
      expect(screens.last.leftoverCodes, isEmpty);

      await tester.tap(find.byType(CupertinoNavigationBarBackButton).last);
      await tester.pumpAndSettle();
      expect(find.byType(PrivateAlbumScreen), findsOneWidget);
      expect(
        tester
            .widget<PrivateAlbumScreen>(find.byType(PrivateAlbumScreen))
            .passcodeHash,
        await tagOf(personAlbumCode('kim', '1234')),
      );

      await tester.tap(find.byType(CupertinoNavigationBarBackButton));
      await tester.pumpAndSettle();
      expect(find.byType(PrivateAlbumScreen), findsNothing);
    });
  });

  testWidgets("a person's folder: a merged person's leftover is a row, "
      'never a second screen', (tester) async {
    final keys = VaultKeys(
      store: FakeSecureStore(),
      derive: deriveOnThisIsolate,
    );
    await keys.add('a good long passphrase');
    await people.merge('kim', 'lee');
    final leeTag = await PasscodeTags(
      records: assets,
      vaultKeys: keys,
    ).tagFor(personAlbumCode('lee', '1234'));
    // Adopted by an older build: can't move, so stays under the alias.
    await assets.upsert(
      localId: 'manual:vault-old',
      contentHash: 'old',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/old.jpg',
    );
    await assets.setPasscodeHash('manual:vault-old', leeTag);
    await tester.pumpWidget(
      _button(
        'open',
        (context) => openPersonHidden(
          context,
          assetRecordStore: assets,
          personStore: people,
          personId: 'kim',
          title: 'Kim',
          vaultKeys: keys,
          countLeftover: (tag, _) async =>
              (await assets.forPasscodeHash(tag)).length,
          carryLeftover: (_, _, _) async => 0,
        ),
      ),
    );
    await tapOpen(tester);
    for (final d in '1234'.split('')) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.byType(PrivateAlbumScreen), findsOneWidget);
    final row = find.byKey(const ValueKey('hiddenLeftover0'));
    await tester.scrollUntilVisible(row, 200);
    expect(find.text('Older photos · 1'), findsOneWidget);

    await tester.tap(find.byType(CupertinoNavigationBarBackButton));
    await tester.pumpAndSettle();
    expect(find.byType(PrivateAlbumScreen), findsNothing);
  });

  testWidgets('Settings: the Me row picks who is me', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(
        SettingsScreen(
          store: BackupTargetsStore(store: FakeSecureStore()),
          assetRecordStore: assets,
          personStore: people,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not set'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settingsMeRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kim'));
    await tester.pumpAndSettle();

    expect(await PersonOwner(assets).id(), 'kim');
    expect(find.text('Kim'), findsOneWidget);
    expect(find.text('Not set'), findsNothing);
  });
}
