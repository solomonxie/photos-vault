import 'dart:io';
import 'dart:typed_data';

import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/viewer/detail_screen.dart';

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
    await tester.tap(find.textContaining('2026'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.text('No Location'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(CupertinoTextField).last,
      'Kyoto, Japan',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Kyoto, Japan'), findsOneWidget);
    final saved = await assetRecordStore.getByLocalId('a');
    expect(saved!.location, 'Kyoto, Japan');
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
    await tester.enterText(find.byType(CupertinoTextField).last, 'sunset');
    await tester.pump();
    await tester.tap(find.text('Add'));
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

  testWidgets(
    'Edit explains a manual file isn\'t in the Photos library, not the plugin',
    (tester) async {
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

      await tester.tap(find.byIcon(CupertinoIcons.pencil));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "This isn't in your Photos library, so it can't be edited there.",
        ),
        findsOneWidget,
      );
    },
  );
}
