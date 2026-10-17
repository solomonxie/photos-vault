import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/asset_grid.dart';
import 'package:photos_vault/viewer/asset_grid_view.dart';
import 'package:photos_vault/viewer/date_scrubber.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

AssetRecord _record(String id, DateTime createdAt) => AssetRecord(
  localId: id,
  contentHash: id,
  platform: 'test',
  sourceType: AssetSourceType.manualFile,
  sourcePath: '/tmp/$id.jpg',
  createdAt: createdAt,
  updatedAt: createdAt,
);

/// Three photos a day, so every row is a full one — the right-hand column
/// is what the scrubber handle floats over.
List<AssetRecord> _dense(int days) {
  final today = DateTime.now();
  return [
    for (var i = days - 1; i >= 0; i--)
      for (var n = 0; n < 3; n++)
        _record(
          'manual:day$i-$n',
          today.subtract(Duration(days: i, hours: 2, minutes: n)),
        ),
  ];
}

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

/// The first grid tile whose rectangle overlaps [rect].
Rect? _tileOverlapping(WidgetTester tester, Rect rect) {
  for (final element in find.byType(AssetTile).evaluate()) {
    final box = element.renderObject! as RenderBox;
    final tile = box.localToGlobal(Offset.zero) & box.size;
    if (tile.overlaps(rect)) return tile;
  }
  return null;
}

/// The grid tile drawn closest to [y] on screen, and where it sits — what
/// "the photo you were looking at" means to a test.
({Key? key, double dy})? _tileNearest(WidgetTester tester, double y) {
  ({Key? key, double dy})? best;
  for (final element in find.byType(AssetTile).evaluate()) {
    final box = element.renderObject! as RenderBox;
    final dy = box.localToGlobal(Offset.zero).dy + box.size.height / 2;
    if (best == null || (dy - y).abs() < (best.dy - y).abs()) {
      best = (key: element.widget.key, dy: dy);
    }
  }
  return best;
}

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
      List<AssetRecord> Function() records, {
      List<Widget> trailing = const [],
    }) async {
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
                trailingSlivers: trailing,
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

    testWidgets('leaves what you were looking at where it was', (tester) async {
      final key = GlobalKey<AssetGridViewState>();
      var records = _daily(40);
      final setOuter = await pumpGrowable(tester, key, () => records);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(key.currentState!.isAtNewest, isFalse);

      // Whatever tile is under the middle of the screen has to still be
      // there afterwards. Holding the *scroll offset* wouldn't do it: the
      // eighty older days land above this one and push it down the page by
      // their own height.
      final middle = tester.getSize(find.byType(AssetGridView)).height / 2;
      final before = _tileNearest(tester, middle);
      expect(before, isNotNull);

      setOuter(() => records = _daily(120));
      await tester.pumpAndSettle();

      final after = _tileNearest(tester, middle);
      expect(after?.key, before!.key);
      expect(after!.dy, closeTo(before.dy, 1));
      expect(
        key.currentState!.scrollController.offset,
        greaterThan(0),
        reason: 'the offset moved; the photo did not',
      );
    });

    testWidgets('holds the page below the grid, where Utilities sits', (
      tester,
    ) async {
      final key = GlobalKey<AssetGridViewState>();
      var records = _daily(40);
      final setOuter = await pumpGrowable(
        tester,
        key,
        () => records,
        trailing: const [
          SliverToBoxAdapter(
            child: SizedBox(key: ValueKey('utilities'), height: 900),
          ),
        ],
      );

      // The foot of the page, past the end of the grid entirely. On the
      // Library that is the Utilities list, which is where the Hidden row
      // is — so it is where the page is standing every time somebody comes
      // back from the private album.
      final controller = key.currentState!.scrollController;
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(find.byKey(const ValueKey('utilities')));

      // Photos come back into the library — a hidden one put back, or a
      // scan that landed while this page was covered.
      setOuter(() => records = _daily(120));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('utilities'))).dy,
        closeTo(before.dy, 1),
        reason: 'the grid grew underneath; the page did not move',
      );
    });
  });

  group('date scrubber', () {
    testWidgets('stays out of the way until the grid actually moves', (
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

      // Nothing on arrival. It used to show itself once so the handle
      // would be discovered, but every page here opens on a grid, so
      // "once" was really "every time".
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

    testWidgets('rides a short track that never drops into the lower page', (
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

      final screen = tester.getSize(find.byType(AssetGridView)).height;
      Rect handle() => tester.getRect(find.byKey(DateScrubber.handleKey));

      // Both ends of the whole library sit in the upper-middle of the
      // screen: never parked against the top edge, where it would read as
      // chrome, and never down among the rows at the bottom, which are what
      // you're reaching for once you've scrolled there.
      key.currentState!.jumpToOldest();
      await tester.pump();
      expect(handle().top, greaterThan(screen * 0.15));

      key.currentState!.jumpToNewest();
      await tester.pump();
      expect(handle().bottom, lessThan(screen * 0.51));
    });

    testWidgets('a tap on the handle reaches what it is floating over', (
      tester,
    ) async {
      AssetRecord? tapped;
      await tester.pumpWidget(
        _wrap(
          AssetGridView(
            records: _dense(40),
            onTap: (record) => tapped = record,
            actionsFor: (_) => _actions,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 40));
      await tester.pump();

      // The handle only wants vertical drags; a tap has to fall through to
      // the photo (or the settings row) underneath it. The handle is taller
      // than a day header, so some tile always overlaps it.
      final handle = tester.getRect(find.byKey(DateScrubber.handleKey));
      final under = _tileOverlapping(tester, handle);
      expect(under, isNotNull, reason: 'nothing under the handle to tap');

      await tester.tapAt(under!.intersect(handle).center);
      await tester.pumpAndSettle();

      expect(tapped, isNotNull);
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

  testWidgets('a context menu action runs once the menu has gone', (
    tester,
  ) async {
    bool? menuGoneWhenRun;
    await tester.pumpWidget(
      _wrap(
        AssetGridView(
          records: _daily(3),
          onTap: (_) {},
          actionsFor: (_) => [
            TileAction(
              icon: CupertinoIcons.delete,
              label: 'Delete',
              onPressed: () => menuGoneWhenRun = find
                  .byType(CupertinoContextMenuAction)
                  .evaluate()
                  .isEmpty,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('manual:day0'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    await hold.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(menuGoneWhenRun, isNull, reason: 'not while the menu closes');
    await tester.pumpAndSettle();
    expect(menuGoneWhenRun, isTrue);
  });

  group('resting on a sliver below the grid', () {
    const inset = 44.0;

    Future<StateSetter> pumpResting(
      WidgetTester tester,
      GlobalKey<AssetGridViewState> key,
      GlobalKey restKey,
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
                restKey: restKey,
                restInset: inset,
                trailingSlivers: [
                  SliverToBoxAdapter(
                    key: restKey,
                    child: const SizedBox(key: ValueKey('rest'), height: 3000),
                  ),
                ],
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return setOuter;
    }

    double restTop(WidgetTester tester, GlobalKey restKey) {
      final sliver =
          restKey.currentContext!.findRenderObject()! as RenderSliver;
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      return sliver.constraints.precedingScrollExtent - position.pixels;
    }

    testWidgets('growth lands already resting, with no frame in between', (
      tester,
    ) async {
      final key = GlobalKey<AssetGridViewState>();
      final restKey = GlobalKey();
      var records = _daily(40);
      final setOuter = await pumpResting(tester, key, restKey, () => records);
      expect(restTop(tester, restKey), closeTo(inset, 0.5));

      setOuter(() => records = _daily(120));
      await tester.pump();

      // As laid out and painted in that one frame, not after a jump.
      final top = tester.getTopLeft(find.byKey(const ValueKey('rest'))).dy;
      expect(top, closeTo(inset, 0.5));
    });

    testWidgets('a rebuild that moved nothing leaves a drag alone', (
      tester,
    ) async {
      final key = GlobalKey<AssetGridViewState>();
      final restKey = GlobalKey();
      final records = _daily(40);
      final setOuter = await pumpResting(tester, key, restKey, () => records);

      final position =
          key.currentState!.scrollController.position
              as ScrollPositionWithSingleContext;
      final drag = position.drag(
        DragStartDetails(globalPosition: Offset.zero),
        () {},
      );
      setOuter(() {});
      await tester.pump();
      await tester.pump();

      expect(position.activity, isA<DragScrollActivity>());
      drag.cancel();
    });

    testWidgets('a rotation keeps the rest', (tester) async {
      final key = GlobalKey<AssetGridViewState>();
      final restKey = GlobalKey();
      await pumpResting(tester, key, restKey, () => _daily(40));

      final view = tester.view;
      view.physicalSize = const Size(2532, 1170);
      await tester.pumpAndSettle();

      expect(restTop(tester, restKey), closeTo(inset, 0.5));
      expect(key.currentState!.isAtNewest, isTrue);
    });

    testWidgets('a rotation keeps the photo being read', (tester) async {
      final key = GlobalKey<AssetGridViewState>();
      final restKey = GlobalKey();
      await pumpResting(tester, key, restKey, () => _daily(120));
      final controller = key.currentState!.scrollController;
      controller.jumpTo(controller.offset / 2);
      await tester.pumpAndSettle();
      final before = _tileNearest(tester, 200)!;

      tester.view.physicalSize = const Size(2532, 1170);
      await tester.pumpAndSettle();

      final tile = find.byKey(before.key!);
      expect(tile, findsOneWidget);
      final rect = tester.getRect(tile);
      expect(rect.bottom, greaterThan(0));
      expect(rect.top, lessThan(tester.view.physicalSize.height / 3));
    });
  });

  testWidgets('the marked photo, and only it, carries the ring', (
    tester,
  ) async {
    final records = _daily(3);
    await tester.pumpWidget(
      _wrap(
        AssetGridView(
          records: records,
          markedId: 'manual:day1',
          onTap: (_) {},
          actionsFor: (_) => _actions,
        ),
      ),
    );
    await tester.pumpAndSettle();

    bool marked(String id) =>
        tester.widget<AssetTile>(find.byKey(ValueKey(id))).marked;
    expect(marked('manual:day1'), isTrue);
    expect(marked('manual:day0'), isFalse);
    expect(marked('manual:day2'), isFalse);
  });

  group('per-tile work', () {
    testWidgets('a rebuild that changed nothing leaves the tiles alone', (
      tester,
    ) async {
      final records = _daily(3);
      late StateSetter rebuild;
      void onTap(AssetRecord _) {}
      List<TileAction> actionsFor(AssetRecord _) => _actions;
      await tester.pumpWidget(
        _wrap(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return AssetGridView(
                records: records,
                onTap: onTap,
                actionsFor: actionsFor,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester.widget(find.byKey(const ValueKey('manual:day0')));

      rebuild(() {});
      await tester.pump();

      expect(
        identical(
          tester.widget(find.byKey(const ValueKey('manual:day0'))),
          before,
        ),
        isTrue,
      );
    });

    testWidgets('a selection change redraws the checkmarks only', (
      tester,
    ) async {
      final selection = ValueNotifier<Set<String>>({});
      addTearDown(selection.dispose);
      await tester.pumpWidget(
        _wrap(
          AssetGridView(
            records: _daily(3),
            onTap: (_) {},
            onLongPress: (_) {},
            actionsFor: (_) => _actions,
            selection: selection,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('manual:day1'));
      final before = tester.widget(tile);
      final checked = find.byIcon(CupertinoIcons.checkmark_circle_fill);
      expect(checked, findsNothing);
      expect(find.byIcon(CupertinoIcons.circle), findsNWidgets(3));

      selection.value = {'manual:day1'};
      await tester.pump();

      expect(find.descendant(of: tile, matching: checked), findsOneWidget);
      expect(checked, findsOneWidget);
      expect(identical(tester.widget(tile), before), isTrue);
    });

    testWidgets('a grid that holds to select never asks for menu actions', (
      tester,
    ) async {
      var asked = 0;
      await tester.pumpWidget(
        _wrap(
          AssetGridView(
            records: _daily(3),
            onTap: (_) {},
            onLongPress: (_) {},
            actionsFor: (_) {
              asked++;
              return _actions;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(asked, 0);
      expect(find.byType(CupertinoContextMenu), findsNothing);
    });

    testWidgets('tiles are rounded without a clip', (tester) async {
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

      final tile = find.byKey(const ValueKey('manual:day0'));
      expect(
        find.descendant(of: tile, matching: find.byType(ClipRRect)),
        findsNothing,
      );
      expect(
        find.descendant(of: tile, matching: find.byType(CustomPaint)),
        findsWidgets,
      );
    });
  });

  testWidgets('a day header reads the date in the current locale', (
    tester,
  ) async {
    const probe = Key('probe');
    await tester.pumpWidget(_wrap(const SizedBox(key: probe)));
    final l10n = AppLocalizations.of(tester.element(find.byKey(probe)))!;
    final day = DateTime(2020, 3, 14);

    expect(dayLabel(l10n, day), DateFormat.yMMMd().format(day));
    expect(dayLabel(l10n, day), dayLabel(l10n, day));
  });

  group('date scrubber timing', () {
    double opacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byType(DateScrubber),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    testWidgets('counts down from when the finger lets go', (tester) async {
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

      final drag = await tester.startGesture(const Offset(200, 400));
      await drag.moveBy(const Offset(0, 40));
      await tester.pump();
      await drag.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(opacity(tester), 1);

      // Held still, past the delay: still up.
      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), 1);

      await drag.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(opacity(tester), 1);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(opacity(tester), 0);
    });
  });
}
