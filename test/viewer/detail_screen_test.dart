import 'dart:io';
import 'dart:typed_data';

import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/ai_analysis.dart';
import 'package:photos_vault/photos/on_device_analysis.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/detail_screen.dart';
import 'package:photos_vault/viewer/zoom_page_route.dart';
import 'package:photos_vault/viewer/search_picker_sheet.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

AssetRecord _record({
  required String localId,
  bool isFavorite = false,
  bool isVideo = false,
}) => AssetRecord(
  localId: localId,
  contentHash: localId,
  platform: 'ios',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  sourceType: AssetSourceType.manualFile,
  sourcePath: '/tmp/$localId.jpg',
  isFavorite: isFavorite,
  isVideo: isVideo,
);

AssetRecord _photoManagerRecord({required String localId}) => AssetRecord(
  localId: 'photo:$localId',
  contentHash: localId,
  platform: 'ios',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  sourceType: AssetSourceType.photoManager,
);

// Smallest possible valid PNG (1x1, transparent).
final _tinyPngBytes = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52, //
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42, 0x60, 0x82,
]);

Future<void> _scrollToInfoPanel(WidgetTester tester) async {
  await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
  await tester.pumpAndSettle();
}

/// The panel is taller than the screen, so anything in it has to be brought
/// into view before it can be tapped — which row ends up off-screen depends
/// on what else the panel is showing.
Future<void> _tapInPanel(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tapping the heart toggles favorite and calls back', (
    tester,
  ) async {
    final record = _record(localId: 'a');
    String? toggledId;

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: FakeAssetRecordStore(),
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (r) async => toggledId = r.localId,
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(CupertinoIcons.heart), findsOneWidget);

    await tester.tap(find.byIcon(CupertinoIcons.heart));
    await tester.pump();

    expect(toggledId, 'a');
    expect(find.byIcon(CupertinoIcons.heart_fill), findsOneWidget);
  });

  testWidgets(
    'dragging the photo down past the threshold dismisses the screen',
    (tester) async {
      final record = _record(localId: 'a');

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => CupertinoButton(
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute(
                  builder: (_) => DetailScreen(
                    records: [record],
                    initialIndex: 0,
                    assetRecordStore: FakeAssetRecordStore(),
                    personStore: FakePersonStore(),
                    onDelete: (_) async => true,
                    onToggleFavorite: (_) async {},
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
      expect(find.byType(DetailScreen), findsOneWidget);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 150));
      await tester.pumpAndSettle();

      expect(find.byType(DetailScreen), findsNothing);
    },
  );

  testWidgets('a pull down that comes out at an angle still dismisses', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () => Navigator.of(context).push(
              CupertinoPageRoute(
                builder: (_) => DetailScreen(
                  records: [
                    _record(localId: 'a'),
                    _record(localId: 'b'),
                  ],
                  initialIndex: 0,
                  assetRecordStore: FakeAssetRecordStore(),
                  personStore: FakePersonStore(),
                  onDelete: (_) async => true,
                  onToggleFavorite: (_) async {},
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

    // Down, but well off vertical — a thumb arcs, it doesn't travel
    // straight. Fed a few pixels at a time, the way a finger arrives: the
    // pager takes this drag, and the pull is read from the pointer anyway.
    await _dragBy(tester, const Offset(3, 3), steps: 30);

    expect(find.byType(DetailScreen), findsNothing);
  });

  testWidgets('a flat sideways swipe still pages instead of dismissing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [
            _record(localId: 'a'),
            _record(localId: 'b'),
          ],
          initialIndex: 0,
          assetRecordStore: FakeAssetRecordStore(),
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();

    // Sideways with a little lift in it — about 11 degrees.
    await _dragBy(tester, const Offset(-15, -3), steps: 40);

    expect(find.byType(DetailScreen), findsOneWidget);
    final pager = tester.widget<PageView>(find.byType(PageView));
    expect(pager.controller!.page, closeTo(1, 0.01));
  });

  testWidgets('the photo comes with the finger, and springs back', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [
            _record(localId: 'a'),
            _record(localId: 'b'),
          ],
          initialIndex: 0,
          assetRecordStore: FakeAssetRecordStore(),
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();

    final photo = find.byType(CustomScrollView).first;
    final resting = tester.getCenter(photo);

    // 48 down, 24 across — a pull, delivered the way a thumb arrives.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(4, 8));
      await tester.pump();
    }

    final held = tester.getCenter(photo);
    expect(held.dy, greaterThan(resting.dy));
    expect(
      held.dx,
      greaterThan(resting.dx),
      reason: 'sideways too — the photo is in hand, not on a rail',
    );
    // The toolbars are out of the way of what's being dragged.
    expect(
      tester
          .widgetList<Opacity>(find.byType(Opacity))
          .any((o) => o.opacity < 1),
      isTrue,
    );

    // Let go short of the threshold and it goes back where it was.
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(DetailScreen), findsOneWidget);
    expect(
      tester.getCenter(photo),
      offsetMoreOrLessEquals(resting, epsilon: 1),
    );
  });

  testWidgets('a small downward drag snaps back instead of dismissing', (
    tester,
  ) async {
    final record = _record(localId: 'a');

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: FakeAssetRecordStore(),
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 20));
    await tester.pumpAndSettle();

    expect(find.byType(DetailScreen), findsOneWidget);
  });

  testWidgets('a suggestion waits on the photo it is about', (tester) async {
    final records = FakeAssetRecordStore();
    final record = await records.upsert(
      localId: 'a',
      contentHash: 'a',
      platform: 'ios',
    );
    final analyses = FakeAiAnalysisStore();
    await analyses.saveSuggestion(
      AiPhotoAnalysis(
        localId: 'a',
        peopleCount: 0,
        eventLabel: 'Beach day',
        analyzedAt: DateTime(2026, 9, 17),
        tags: const ['beach'],
        description: 'A day at the beach.',
      ),
    );

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: records,
          personStore: FakePersonStore(),
          onDeviceAnalysis: OnDeviceAnalysisService(analysisStore: analyses),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollToInfoPanel(tester);

    // On the photo it's about, where the picture is — not in a list of
    // little cards somewhere else.
    expect(find.text('Suggested'), findsOneWidget);
    expect(find.text('A day at the beach.'), findsOneWidget);
    expect(find.text('beach'), findsOneWidget);

    await _tapInPanel(tester, find.text('Keep'));

    final after = (await records.getByLocalId('a'))!;
    expect(after.tags, ['beach']);
    expect(after.description, 'A day at the beach.');
    expect(after.event, 'Beach day');
    // Answered, so it stops asking.
    expect(find.text('Suggested'), findsNothing);
  });

  testWidgets('turning a suggestion down leaves the photo as it was', (
    tester,
  ) async {
    final records = FakeAssetRecordStore();
    final record = await records.upsert(
      localId: 'a',
      contentHash: 'a',
      platform: 'ios',
    );
    final analyses = FakeAiAnalysisStore();
    await analyses.saveSuggestion(
      AiPhotoAnalysis(
        localId: 'a',
        peopleCount: 0,
        eventLabel: '',
        analyzedAt: DateTime(2026, 9, 17),
        tags: const ['beach'],
      ),
    );

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: records,
          personStore: FakePersonStore(),
          onDeviceAnalysis: OnDeviceAnalysisService(analysisStore: analyses),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollToInfoPanel(tester);

    await _tapInPanel(tester, find.text('No thanks'));

    expect((await records.getByLocalId('a'))!.tags, isEmpty);
    expect(find.text('Suggested'), findsNothing);
  });

  testWidgets('Done pops the screen', (tester) async {
    final record = _record(localId: 'a');

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () => Navigator.of(context).push(
              CupertinoPageRoute(
                builder: (_) => DetailScreen(
                  records: [record],
                  initialIndex: 0,
                  assetRecordStore: FakeAssetRecordStore(),
                  personStore: FakePersonStore(),
                  onDelete: (_) async => true,
                  onToggleFavorite: (_) async {},
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
    expect(find.byType(DetailScreen), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailScreen), findsNothing);
  });

  testWidgets(
    'a photoManager record resolves its file instead of showing unavailable',
    (tester) async {
      final record = _photoManagerRecord(localId: 'a1');
      final tempFile = File(
        '${Directory.systemTemp.path}/detail_screen_test_a1.png',
      )..writeAsBytesSync(_tinyPngBytes);
      addTearDown(() => tempFile.deleteSync());

      await tester.pumpWidget(
        _wrap(
          DetailScreen(
            records: [record],
            initialIndex: 0,
            assetRecordStore: FakeAssetRecordStore(),
            personStore: FakePersonStore(),
            onDelete: (_) async => true,
            onToggleFavorite: (_) async {},
            resolvePhotoManagerFile: (_) async => tempFile,
          ),
        ),
      );
      // Still resolving: a spinner, not the "unavailable" note.
      await tester.pump();
      expect(
        find.byIcon(CupertinoIcons.exclamationmark_triangle),
        findsNothing,
      );

      // Let the resolver's future complete and the widget rebuild.
      await tester.pump();

      expect(
        find.byIcon(CupertinoIcons.exclamationmark_triangle),
        findsNothing,
      );
      expect(find.byType(Image), findsOneWidget);
    },
  );

  testWidgets(
    'a photoManager record removed from the library shows the unavailable note',
    (tester) async {
      final record = _photoManagerRecord(localId: 'gone');

      await tester.pumpWidget(
        _wrap(
          DetailScreen(
            records: [record],
            initialIndex: 0,
            assetRecordStore: FakeAssetRecordStore(),
            personStore: FakePersonStore(),
            onDelete: (_) async => true,
            onToggleFavorite: (_) async {},
            resolvePhotoManagerFile: (_) async => null,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byIcon(CupertinoIcons.exclamationmark_triangle),
        findsOneWidget,
      );
    },
  );

  testWidgets('double-tapping a photo zooms in, and again zooms back out', (
    tester,
  ) async {
    final tempFile = File(
      '${Directory.systemTemp.path}/detail_screen_test_zoom.png',
    )..writeAsBytesSync(_tinyPngBytes);
    addTearDown(() => tempFile.deleteSync());
    final record = _record(localId: 'zoom')
        .withSourcePath(tempFile.path, DateTime(2026, 1, 1));

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: FakeAssetRecordStore(),
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();

    final viewerFinder = find.byType(InteractiveViewer);
    expect(viewerFinder, findsOneWidget);
    double scale() => tester
        .widget<InteractiveViewer>(viewerFinder)
        .transformationController!
        .value
        .getMaxScaleOnAxis();
    expect(scale(), closeTo(1, 0.01));

    Future<void> doubleTapAt(Offset position) async {
      await tester.tapAt(position);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(position);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    final center = tester.getCenter(viewerFinder);
    await doubleTapAt(center);
    expect(scale(), greaterThan(2));

    await doubleTapAt(center);
    expect(scale(), closeTo(1, 0.01));
  });

  testWidgets('editing the date/time via the header persists it', (
    tester,
  ) async {
    final record = _record(localId: 'a');
    final assetRecordStore = FakeAssetRecordStore();
    await assetRecordStore.upsert(
      localId: record.localId,
      contentHash: record.localId,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: record.sourcePath,
      createdAt: record.createdAt,
    );

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: assetRecordStore,
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await _scrollToInfoPanel(tester);

    // Round-trips through the sheet without corrupting the value (dragging
    // the picker's wheels to a specific date isn't exercised here).
    await _tapInPanel(tester, find.textContaining('2026'));
    expect(find.text('Date & Time'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = await assetRecordStore.getByLocalId('a');
    expect(saved!.createdAt, DateTime(2026, 1, 1));
  });

  testWidgets('editing the location shows it in place of "No Location"', (
    tester,
  ) async {
    final record = _record(localId: 'a');
    final assetRecordStore = FakeAssetRecordStore();
    await assetRecordStore.upsert(
      localId: record.localId,
      contentHash: record.localId,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: record.sourcePath,
      createdAt: record.createdAt,
    );

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: assetRecordStore,
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await _scrollToInfoPanel(tester);

    expect(find.text('No Location'), findsOneWidget);
    await _tapInPanel(tester, find.text('No Location'));
    await tester.enterText(find.byKey(searchPickerFieldKey), 'Kyoto, Japan');
    await tester.pump();
    await tester.tap(find.text('Use "Kyoto, Japan"'));
    await tester.pumpAndSettle();

    expect(find.text('Kyoto, Japan'), findsOneWidget);
    final saved = await assetRecordStore.getByLocalId('a');
    expect(saved!.location, 'Kyoto, Japan');
  });

  testWidgets('editing the event shows it in place of "No Event"', (
    tester,
  ) async {
    final record = _record(localId: 'a');
    final assetRecordStore = FakeAssetRecordStore();
    await assetRecordStore.upsert(
      localId: record.localId,
      contentHash: record.localId,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: record.sourcePath,
      createdAt: record.createdAt,
    );

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: assetRecordStore,
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await _scrollToInfoPanel(tester);

    expect(find.text('No Event'), findsOneWidget);
    await tester.tap(find.text('No Event'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(searchPickerFieldKey), "Nina's Wedding");
    await tester.pump();
    await tester.tap(find.text('Use "Nina\'s Wedding"'));
    await tester.pumpAndSettle();

    expect(find.text("Nina's Wedding"), findsOneWidget);
    final saved = await assetRecordStore.getByLocalId('a');
    expect(saved!.event, "Nina's Wedding");
  });

  testWidgets('editing the description persists it', (tester) async {
    final record = _record(localId: 'a');
    final assetRecordStore = FakeAssetRecordStore();
    await assetRecordStore.upsert(
      localId: record.localId,
      contentHash: record.localId,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: record.sourcePath,
      createdAt: record.createdAt,
    );

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: assetRecordStore,
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await _scrollToInfoPanel(tester);

    await tester.enterText(
      find.widgetWithText(
        CupertinoTextField,
        'Add a description',
        skipOffstage: false,
      ),
      'A trip to the mountains.',
    );
    await tester.pump();

    final saved = await assetRecordStore.getByLocalId('a');
    expect(saved!.description, 'A trip to the mountains.');
  });

  testWidgets('adding then removing a tag persists both changes', (
    tester,
  ) async {
    final record = _record(localId: 'a');
    final assetRecordStore = FakeAssetRecordStore();
    await assetRecordStore.upsert(
      localId: record.localId,
      contentHash: record.localId,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: record.sourcePath,
      createdAt: record.createdAt,
    );

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: assetRecordStore,
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await _scrollToInfoPanel(tester);

    await tester.tap(find.text('Tags'));
    await tester.pump();
    await tester.tap(
      find.byIcon(CupertinoIcons.add_circled, skipOffstage: false).first,
    );
    await tester.pumpAndSettle();

    // A compact popup, not a full-page push — the search field sits well
    // below the screen's midpoint, not flush with the top.
    final searchFieldTop = tester
        .getTopLeft(find.byKey(searchPickerFieldKey))
        .dy;
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(searchFieldTop, greaterThan(screenHeight * 0.4));

    await tester.enterText(find.byKey(searchPickerFieldKey), 'sunset');
    await tester.pump();
    await tester.tap(find.text('Use "sunset"'));
    await tester.pumpAndSettle();

    expect(find.text('sunset'), findsOneWidget);
    var saved = await assetRecordStore.getByLocalId('a');
    expect(saved!.tags, ['sunset']);

    await tester.tap(find.byIcon(CupertinoIcons.xmark_circle_fill));
    await tester.pump();

    saved = await assetRecordStore.getByLocalId('a');
    expect(saved!.tags, isEmpty);
  });

  testWidgets('tagging then untagging a person persists both changes', (
    tester,
  ) async {
    final record = _record(localId: 'a');
    final assetRecordStore = FakeAssetRecordStore();
    await assetRecordStore.upsert(
      localId: record.localId,
      contentHash: record.localId,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: record.sourcePath,
      createdAt: record.createdAt,
    );
    final personStore = FakePersonStore();
    await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: assetRecordStore,
          personStore: personStore,
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await _scrollToInfoPanel(tester);

    await tester.tap(find.text('People'));
    await tester.pump();
    await tester.tap(
      find.byIcon(CupertinoIcons.add_circled, skipOffstage: false).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mia'));
    await tester.pumpAndSettle();

    expect(find.text('Mia'), findsOneWidget);
    var tagged = await personStore.peopleFor('a');
    expect(tagged.map((p) => p.name), ['Mia']);

    await tester.tap(find.byIcon(CupertinoIcons.xmark_circle_fill));
    await tester.pumpAndSettle();

    tagged = await personStore.peopleFor('a');
    expect(tagged, isEmpty);
  });

  testWidgets('tapping a tagged person opens their own page', (tester) async {
    final record = _record(localId: 'a');
    final assetRecordStore = FakeAssetRecordStore();
    await assetRecordStore.upsert(
      localId: record.localId,
      contentHash: record.localId,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: record.sourcePath,
      createdAt: record.createdAt,
    );
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.addAssets(mia.id, ['a']);

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: assetRecordStore,
          personStore: personStore,
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await _scrollToInfoPanel(tester);

    await tester.tap(find.text('Mia'));
    await tester.pumpAndSettle();

    // Lands on Mia's own page, not an edit sheet.
    expect(find.text('Mia'), findsWidgets);
    expect(find.byType(CupertinoNavigationBarBackButton), findsOneWidget);
  });

  testWidgets('the info-circle button reveals the info panel below', (
    tester,
  ) async {
    final record = _record(localId: 'a');
    final assetRecordStore = FakeAssetRecordStore();
    await assetRecordStore.upsert(
      localId: record.localId,
      contentHash: record.localId,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: record.sourcePath,
      createdAt: record.createdAt,
    );

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: assetRecordStore,
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('No Location', skipOffstage: false), findsOneWidget);
    expect(find.text('No Location'), findsNothing);

    await tester.tap(find.byIcon(CupertinoIcons.info_circle));
    await tester.pumpAndSettle();

    expect(find.text('No Location'), findsOneWidget);
  });

  testWidgets('the share sheet offers "Export As…" for a photo, not a video', (
    tester,
  ) async {
    final photo = _record(localId: 'a');
    final video = _record(localId: 'b', isVideo: true);

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [photo, video],
          initialIndex: 0,
          assetRecordStore: FakeAssetRecordStore(),
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(CupertinoIcons.share));
    await tester.pumpAndSettle();
    expect(find.text('Share Original'), findsOneWidget);
    expect(find.text('Export As…'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(PageView), const Offset(-800, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.share));
    await tester.pumpAndSettle();
    expect(find.text('Share Original'), findsOneWidget);
    expect(find.text('Export As…'), findsNothing);
  });

  testWidgets('Edit opens the crop/rotate/AI touch-up menu', (tester) async {
    final record = _record(localId: 'a');

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          assetRecordStore: FakeAssetRecordStore(),
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.text('Crop'), findsOneWidget);
    expect(find.text('Rotate'), findsOneWidget);
    expect(find.text('AI Touch Up'), findsOneWidget);
  });

  group('cloud-only', () {
    AssetRecord cloudOnly() => AssetRecord(
      localId: 'manual:gone',
      contentHash: 'gone',
      platform: 'ios',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/gone.jpg',
      thumbnailPath: '/tmp/gone-thumb.jpg',
      localDeleted: true,
      derivatives: const {
        DerivativeKind.original: DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'originals/manual_gone.jpg',
        ),
      },
    );

    Widget screen({required Future<String?> Function(AssetRecord) restore}) =>
        _wrap(
          DetailScreen(
            records: [cloudOnly()],
            initialIndex: 0,
            assetRecordStore: FakeAssetRecordStore(),
            personStore: FakePersonStore(),
            onDelete: (_) async => true,
            onToggleFavorite: (_) async {},
            restoreOriginal: restore,
          ),
        );

    testWidgets(
      'offers to download the full resolution instead of the missing original',
      (tester) async {
        await tester.pumpWidget(screen(restore: (_) async => null));
        await tester.pump();

        expect(find.text('Download Full Resolution'), findsOneWidget);
        // Drawn from the cached thumbnail, not the deleted original.
        final image = tester.widget<Image>(find.byType(Image).first);
        expect((image.image as FileImage).file.path, '/tmp/gone-thumb.jpg');
      },
    );

    testWidgets('a successful download swaps in the restored original', (
      tester,
    ) async {
      await tester.pumpWidget(
        screen(restore: (_) async => '/tmp/restored.jpg'),
      );
      await tester.pump();

      await tester.tap(find.text('Download Full Resolution'));
      await tester.pumpAndSettle();

      expect(find.text('Download Full Resolution'), findsNothing);
      final image = tester.widget<Image>(find.byType(Image).first);
      expect((image.image as FileImage).file.path, '/tmp/restored.jpg');
    });

    testWidgets('a failed download leaves the offer up to try again', (
      tester,
    ) async {
      await tester.pumpWidget(
        screen(restore: (_) async => throw Exception('offline')),
      );
      await tester.pump();

      await tester.tap(find.text('Download Full Resolution'));
      await tester.pumpAndSettle();

      expect(find.text('Download Full Resolution'), findsOneWidget);
    });
  });

  group('location from the photo\'s own metadata', () {
    testWidgets('fills an empty Location and saves it', (tester) async {
      final store = FakeAssetRecordStore();
      final record = _record(localId: 'geo');
      await store.upsert(
        localId: record.localId,
        contentHash: record.contentHash,
        platform: record.platform,
        sourceType: AssetSourceType.manualFile,
        sourcePath: record.sourcePath,
      );

      await tester.pumpWidget(
        _wrap(
          DetailScreen(
            records: [record],
            initialIndex: 0,
            assetRecordStore: store,
            personStore: FakePersonStore(),
            resolvePlaceName: (_) async => 'Kyoto, Japan',
            onDelete: (_) async => true,
            onToggleFavorite: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _scrollToInfoPanel(tester);

      expect(find.text('Kyoto, Japan'), findsOneWidget);
      expect(
        (await store.getByLocalId('geo'))?.location,
        'Kyoto, Japan',
        reason: 'persisted, not just shown',
      );
    });

    testWidgets('never overwrites a place the user typed', (tester) async {
      final store = FakeAssetRecordStore();
      final record = _record(localId: 'typed').withLocation('Home');
      var geocoded = false;

      await tester.pumpWidget(
        _wrap(
          DetailScreen(
            records: [record],
            initialIndex: 0,
            assetRecordStore: store,
            personStore: FakePersonStore(),
            resolvePlaceName: (_) async {
              geocoded = true;
              return 'Kyoto, Japan';
            },
            onDelete: (_) async => true,
            onToggleFavorite: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _scrollToInfoPanel(tester);

      expect(geocoded, isFalse);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('an untagged photo just stays "No Location"', (tester) async {
      await tester.pumpWidget(
        _wrap(
          DetailScreen(
            records: [_record(localId: 'plain')],
            initialIndex: 0,
            assetRecordStore: FakeAssetRecordStore(),
            personStore: FakePersonStore(),
            resolvePlaceName: (_) async => null,
            onDelete: (_) async => true,
            onToggleFavorite: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _scrollToInfoPanel(tester);

      expect(find.text('No Location'), findsOneWidget);
    });
  });

  group('opening and dismissing', () {
    testWidgets('opens by zooming out of the middle, not sliding in', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => CupertinoButton(
              onPressed: () => Navigator.of(context).push(
                ZoomPageRoute<void>(
                  builder: (_) => DetailScreen(
                    records: [_record(localId: 'a')],
                    initialIndex: 0,
                    assetRecordStore: FakeAssetRecordStore(),
                    personStore: FakePersonStore(),
                    onDelete: (_) async => true,
                    onToggleFavorite: (_) async {},
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // Mid-flight it's smaller than full size and see-through, rather
      // than off to one side.
      final scale = tester.widget<ScaleTransition>(
        find.byType(ScaleTransition).last,
      );
      expect(scale.scale.value, lessThan(1));
      expect(scale.scale.value, greaterThan(0.5));

      await tester.pumpAndSettle();
      expect(find.byType(DetailScreen), findsOneWidget);
    });

    testWidgets('a short pull down is enough to dismiss', (tester) async {
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => CupertinoButton(
              onPressed: () => Navigator.of(context).push(
                ZoomPageRoute<void>(
                  builder: (_) => DetailScreen(
                    records: [_record(localId: 'a')],
                    initialIndex: 0,
                    assetRecordStore: FakeAssetRecordStore(),
                    personStore: FakePersonStore(),
                    onDelete: (_) async => true,
                    onToggleFavorite: (_) async {},
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

      // Bouncing physics hand back roughly a third of the drag past the
      // edge, so this is a modest pull — well short of the half-screen
      // haul the old threshold needed.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 120));
      await tester.pumpAndSettle();

      expect(find.byType(DetailScreen), findsNothing);
    });
  });

  testWidgets('the keyboard leaves the page where it is', (tester) async {
    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [_record(localId: 'a')],
          initialIndex: 0,
          assetRecordStore: FakeAssetRecordStore(),
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.getSize(find.byType(CustomScrollView).first);

    // A caption field takes focus: the keyboard covers the bottom of the
    // screen. The page must not relayout around it — that's what dragged
    // the photo and everything under it upward.
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(CustomScrollView).first), before);
  });

  group('zoomed in', () {
    Future<void> pumpPair(WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          DetailScreen(
            records: [
              _record(localId: 'a'),
              _record(localId: 'b'),
            ],
            initialIndex: 0,
            assetRecordStore: FakeAssetRecordStore(),
            personStore: FakePersonStore(),
            onDelete: (_) async => true,
            onToggleFavorite: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Double-tap is the zoom this test can drive; pinch needs two pointers
    /// and the same state comes out either way.
    Future<void> zoom(WidgetTester tester) async {
      final centre = tester.getCenter(find.byType(InteractiveViewer).first);
      await tester.tapAt(centre);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(centre);
      await tester.pumpAndSettle();
    }

    testWidgets('a drag pans the photo instead of turning the page', (
      tester,
    ) async {
      await pumpPair(tester);
      final pager = tester.widget<PageView>(find.byType(PageView));
      expect(pager.physics, isNot(isA<NeverScrollableScrollPhysics>()));

      await zoom(tester);

      // The pager stands down entirely — panning a zoomed photo and
      // swiping to the next one are the same gesture, and the pager wins
      // it by default.
      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>(),
      );
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView).first)
            .physics,
        isA<NeverScrollableScrollPhysics>(),
        reason: 'and so does the info panel, for vertical drags',
      );
    });

    testWidgets('and zooming back out hands the page back', (tester) async {
      await pumpPair(tester);
      await zoom(tester);
      await zoom(tester);

      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isNot(isA<NeverScrollableScrollPhysics>()),
      );
    });
  });

  testWidgets('AI Suggest sits above Tags, and Find Faces is on People', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [_record(localId: 'a')],
          initialIndex: 0,
          assetRecordStore: FakeAssetRecordStore(),
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollToInfoPanel(tester);

    // Tagging is the vendor models' job, so its button leads the Tags
    // section; finding faces fills in People, so it sits under that
    // heading.
    expect(
      tester.getTopLeft(find.text('AI Suggest')).dy,
      lessThan(tester.getTopLeft(find.text('Tags')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Find Faces')).dy,
      greaterThan(tester.getTopLeft(find.text('Tags')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Find Faces')).dy,
      greaterThan(tester.getBottomLeft(find.text('People')).dy),
      reason: 'a row of its own under the heading, not inside it',
    );
  });

  testWidgets('a photo with coordinates offers a pin; one without does not', (
    tester,
  ) async {
    final store = FakeAssetRecordStore();
    final tagged = await store.upsert(
      localId: 'gps',
      contentHash: 'gps',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/gps.jpg',
      latitude: 35.0116,
      longitude: 135.7681,
    );

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [tagged],
          initialIndex: 0,
          assetRecordStore: store,
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(DetailScreen), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.byIcon(CupertinoIcons.map_pin_ellipse), findsOneWidget);
  });

  testWidgets('no coordinates, no pin — a typed place name is not a map', (
    tester,
  ) async {
    final store = FakeAssetRecordStore();
    final untagged = await store.upsert(
      localId: 'plain',
      contentHash: 'plain',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/plain.jpg',
    );
    await store.setLocation('plain', 'Kyoto');

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [untagged],
          initialIndex: 0,
          assetRecordStore: store,
          personStore: FakePersonStore(),
          onDelete: (_) async => true,
          onToggleFavorite: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(DetailScreen), const Offset(0, -600));
    await tester.pumpAndSettle();

    // A pin that opens the wrong street is worse than no pin.
    expect(find.byIcon(CupertinoIcons.map_pin_ellipse), findsNothing);
  });
}

/// A drag delivered in small steps from the middle of the page, so the
/// gesture arena resolves it the way a real finger would rather than in one
/// jump past everyone's slop.
Future<void> _dragBy(
  WidgetTester tester,
  Offset step, {
  required int steps,
}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(PageView)),
  );
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(step);
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}
