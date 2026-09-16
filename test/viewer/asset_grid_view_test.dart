import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:bring_your_own_photos/viewer/asset_grid.dart';
import 'package:bring_your_own_photos/viewer/asset_grid_view.dart';
import 'package:bring_your_own_photos/viewer/date_scrubber.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

AssetRecord _record(String id, DateTime createdAt) => AssetRecord(
  localId: id,
  contentHash: id,
  platform: 'test',
  sourceType: AssetSourceType.manualFile,
  sourcePath: '/tmp/$id.jpg',
  createdAt: createdAt,
  updatedAt: createdAt,
);

/// One photo a day, oldest first — `days` days ending today.
List<AssetRecord> _daily(int days) {
  final today = DateTime.now();
  return [
    for (var i = days - 1; i >= 0; i--)
      _record('manual:day$i', today.subtract(Duration(days: i, hours: 2))),
  ];
}

const _actions = [
  TileAction(icon: CupertinoIcons.heart, label: 'Favorite', onPressed: _noop),
];

void _noop() {}

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: CupertinoPageScaffold(child: child),
);

void main() {
  // A phone-sized surface, not the 800x600 test default — tile size (and
  // so how much library fits on screen) is what these tests are about.
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1170, 2532);
    view.devicePixelRatio = 3;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  testWidgets('opens on the newest photos, not the oldest', (tester) async {
    final records = _daily(40);
    final key = GlobalKey<AssetGridViewState>();

    await tester.pumpWidget(
      _wrap(
        AssetGridView(
          key: key,
          records: records,
          onTap: (_) {},
          actionsFor: (_) => _actions,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:day0')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:day39')), findsNothing);
    expect(key.currentState!.isAtNewest, isTrue);
  });

  testWidgets('a short library needs no jump and stays at the top', (
    tester,
  ) async {
    final key = GlobalKey<AssetGridViewState>();

    await tester.pumpWidget(
      _wrap(
        AssetGridView(
          key: key,
          records: _daily(2),
          onTap: (_) {},
          actionsFor: (_) => _actions,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(key.currentState!.scrollController.offset, 0);
    expect(find.byKey(const ValueKey('manual:day1')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:day0')), findsOneWidget);
  });

  testWidgets('toggleAnchor goes to the top, then back to the newest', (
    tester,
  ) async {
    final key = GlobalKey<AssetGridViewState>();

    await tester.pumpWidget(
      _wrap(
        AssetGridView(
          key: key,
          records: _daily(40),
          onTap: (_) {},
          actionsFor: (_) => _actions,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final newest = key.currentState!.scrollController.offset;
    expect(newest, greaterThan(0));

    key.currentState!.toggleAnchor();
    await tester.pumpAndSettle();
    expect(key.currentState!.scrollController.offset, 0);
    expect(find.byKey(const ValueKey('manual:day39')), findsOneWidget);

    key.currentState!.toggleAnchor();
    await tester.pumpAndSettle();
    expect(key.currentState!.scrollController.offset, newest);
  });

  group('a later scan brings more photos in', () {
    Future<StateSetter> pumpGrowable(
      WidgetTester tester,
      GlobalKey<AssetGridViewState> key,
      List<AssetRecord> Function() records,
    ) async {
      late StateSetter setOuter;
      await tester.pumpWidget(
        _wrap(
          StatefulBuilder(
            builder: (context, setState) {
              setOuter = setState;
              return AssetGridView(
                key: key,
                records: records(),
                onTap: (_) {},
                actionsFor: (_) => _actions,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return setOuter;
    }

    testWidgets('follows the anchor while resting on it', (tester) async {
      final key = GlobalKey<AssetGridViewState>();
      var records = _daily(40);
      final setOuter = await pumpGrowable(tester, key, () => records);

      final before = key.currentState!.scrollController.offset;
      setOuter(() => records = _daily(120));
      await tester.pumpAndSettle();

      expect(key.currentState!.scrollController.offset, greaterThan(before));
      expect(key.currentState!.isAtNewest, isTrue);
    });

    testWidgets('leaves a scrolled-away position where it is', (tester) async {
      final key = GlobalKey<AssetGridViewState>();
      var records = _daily(40);
      final setOuter = await pumpGrowable(tester, key, () => records);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
      await tester.pumpAndSettle();
      final scrolledTo = key.currentState!.scrollController.offset;
      expect(key.currentState!.isAtNewest, isFalse);

      setOuter(() => records = _daily(120));
      await tester.pumpAndSettle();

      expect(key.currentState!.scrollController.offset, scrolledTo);
    });
  });

  group('date scrubber', () {
    testWidgets('introduces itself once, then gets out of the way', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          AssetGridView(
            records: _daily(40),
            onTap: (_) {},
            actionsFor: (_) => _actions,
          ),
        ),
      );
      await tester.pumpAndSettle();

      double opacity() => tester
          .widget<AnimatedOpacity>(
            find.descendant(
              of: find.byType(DateScrubber),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity;

      // Shown unprompted on arrival — a handle that only appears after
      // you've started thumbing is one nobody discovers…
      expect(opacity(), 1);

      // …then it goes away on its own.
      await tester.pumpAndSettle(const Duration(seconds: 4));
      expect(opacity(), 0);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 120));
      await tester.pump();
      expect(opacity(), 1);

      // …and back out once scrolling stops.
      await tester.pumpAndSettle(const Duration(seconds: 4));
      expect(opacity(), 0);
    });

    testWidgets('dragging the handle scrolls years at a time', (tester) async {
      final key = GlobalKey<AssetGridViewState>();

      await tester.pumpWidget(
        _wrap(
          AssetGridView(
            key: key,
            records: _daily(40),
            onTap: (_) {},
            actionsFor: (_) => _actions,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Wake it up, then grab the handle and pull it to the top.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 40));
      await tester.pump();

      final before = key.currentState!.scrollController.offset;
      await tester.drag(
        find.byKey(DateScrubber.handleKey),
        const Offset(0, -400),
      );
      await tester.pump();

      // A 400pt pull covers most of the track, so it should cross most of
      // the library — not the handful of rows the same drag on the grid
      // itself would.
      expect(
        key.currentState!.scrollController.offset,
        lessThan(before - 3000),
      );
    });

    testWidgets('never appears for a library that barely scrolls', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          AssetGridView(
            records: _daily(3),
            onTap: (_) {},
            actionsFor: (_) => _actions,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -80));
      await tester.pump();

      expect(find.byKey(DateScrubber.handleKey), findsNothing);
    });
  });
}
