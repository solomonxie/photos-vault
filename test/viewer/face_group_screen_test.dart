import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/face_grouping.dart';
import 'package:photos_vault/photos/face_identity.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/viewer/asset_grid_view.dart';
import 'package:photos_vault/viewer/face_group_screen.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

const _face = FaceRect(0.3, 0.3, 0.4, 0.4);
const _seed = UnnamedFace(localId: 'a', face: _face);

void main() {
  late FakeAiAnalysisStore analyses;
  late FakeAssetRecordStore records;
  late FakePersonStore people;

  setUp(() {
    analyses = FakeAiAnalysisStore();
    records = FakeAssetRecordStore();
    people = FakePersonStore();
  });

  Future<void> describe(String id, List<double> v) async {
    await records.upsert(localId: id, contentHash: id, platform: 'ios');
    await analyses.saveDescriptor(
      localId: id,
      face: _face,
      descriptor: FaceDescriptor(vector: Float32List.fromList(v), revision: 1),
    );
  }

  Widget screen() => _wrap(
    FaceGroupScreen(
      seed: _seed,
      personStore: people,
      assetRecordStore: records,
      grouping: FaceGrouping(analysisStore: analyses, ceiling: 0.3),
      faceIdentity: FaceIdentityService(
        analysisStore: analyses,
        resolvePath: (_) async => null,
      ),
    ),
  );

  testWidgets('Save is dead with nothing kept, name or no name', (
    tester,
  ) async {
    await describe('a', [1, 0, 0]);
    await describe('b', [1, 0.05, 0]);

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoSearchTextField), 'Nina');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deselect All'));
    await tester.pumpAndSettle();

    // A named person made of no photos is a button that lies.
    final save = tester.widget<CupertinoButton>(
      find.ancestor(
        of: find.text('Save'),
        matching: find.byType(CupertinoButton),
      ),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('Save is dead until the person has a name', (tester) async {
    await describe('a', [1, 0, 0]);

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    // The rule this screen is built on is "nothing is saved until you
    // name it" — a dead button says that, a hidden one doesn't.
    var save = tester.widget<CupertinoButton>(
      find.ancestor(
        of: find.text('Save'),
        matching: find.byType(CupertinoButton),
      ),
    );
    expect(save.onPressed, isNull);

    await tester.enterText(find.byType(CupertinoSearchTextField), 'Nina');
    await tester.pumpAndSettle();

    save = tester.widget<CupertinoButton>(
      find.ancestor(
        of: find.text('Save'),
        matching: find.byType(CupertinoButton),
      ),
    );
    expect(save.onPressed, isNotNull);
  });

  testWidgets('tapping the empty field offers the people you tag most', (
    tester,
  ) async {
    await describe('a', [1, 0, 0]);
    final often = await people.create(name: 'Nina');
    await people.create(name: 'Sam');
    await people.addAssets(often.id, ['x', 'y', 'z']);

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    // Nothing offered until asked — the page is about the faces.
    expect(find.text('Nina'), findsNothing);

    await tester.tap(find.byType(CupertinoSearchTextField));
    await tester.pumpAndSettle();

    expect(find.text('Nina'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    // Most-tagged first: typing a name out to find it is work the app can
    // do instead.
    expect(
      tester.getTopLeft(find.text('Nina')).dy,
      lessThan(tester.getTopLeft(find.text('Sam')).dy),
    );
  });

  testWidgets('typing offers people already named, and a new one', (
    tester,
  ) async {
    await describe('a', [1, 0, 0]);
    await people.create(name: 'Nina');

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoSearchTextField), 'Nin');
    await tester.pumpAndSettle();

    expect(find.text('Nina'), findsOneWidget);
    expect(find.text('New Person "Nin"'), findsOneWidget);
  });

  testWidgets('picking an existing person adds to them, makes nobody new', (
    tester,
  ) async {
    await describe('a', [1, 0, 0]);
    await describe('b', [1, 0.05, 0]);
    final nina = await people.create(name: 'Nina');

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoSearchTextField), 'Nina');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('pick:${nina.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(await people.listAll(), hasLength(1), reason: 'no second Nina');
    expect((await people.localIdsIn(nina.id)).toSet(), {
      'a',
      'b',
    }, reason: 'the whole group goes to them');
  });

  testWidgets('one button clears the group, then takes the lot back', (
    tester,
  ) async {
    await describe('a', [1, 0, 0]);
    await describe('b', [1, 0.05, 0]);
    await describe('c', [1, 0.1, 0]);

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    // Everything starts in, so the only move left is to clear it.
    expect(find.text('Deselect All'), findsOneWidget);
    await tester.tap(find.text('Deselect All'));
    await tester.pumpAndSettle();

    // Every tile drops, the seed included — it sits at the bottom of an
    // oldest-first grid, and a tile that won't toggle reads as broken.
    expect(find.text('0 photos look like this face'), findsOneWidget);
    expect(find.text('Select All'), findsOneWidget);

    await tester.tap(find.text('Select All'));
    await tester.pumpAndSettle();

    expect(find.text('3 photos look like this face'), findsOneWidget);
  });

  testWidgets('the New Person row makes the person, not just a hint', (
    tester,
  ) async {
    await describe('a', [1, 0, 0]);
    await describe('b', [1, 0.05, 0]);

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoSearchTextField), 'Sam');
    await tester.pumpAndSettle();

    // A row reading "New Person" that makes no person is a button that
    // looks broken.
    await tester.tap(find.byKey(const ValueKey('pick:new')));
    await tester.pumpAndSettle();

    final made = (await people.listAll()).single;
    expect(made.name, 'Sam');
    expect((await people.localIdsIn(made.id)).toSet(), {'a', 'b'});
  });

  testWidgets('a name nobody has makes a new person from the group', (
    tester,
  ) async {
    await describe('a', [1, 0, 0]);
    await describe('b', [1, 0.05, 0]);

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoSearchTextField), 'Sam');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final created = (await people.listAll()).single;
    expect(created.name, 'Sam');
    expect((await people.localIdsIn(created.id)).toSet(), {'a', 'b'});
    // The face that was tapped becomes their picture.
    expect(created.avatarLocalId, 'a');
  });

  testWidgets('the face you came from is ringed in the grid', (tester) async {
    await describe('a', [1, 0, 0]);
    await describe('b', [1, 0.05, 0]);

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    // In a grid of near-identical photos, "the one you came from" is
    // otherwise indistinguishable from the ones it gathered.
    final grid = tester.widget<AssetGridView>(find.byType(AssetGridView));
    expect(grid.markedId, 'a');
  });
}
