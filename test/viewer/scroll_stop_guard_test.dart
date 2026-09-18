import 'package:bring_your_own_photos/viewer/scroll_stop_guard.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

const _middle = Offset(200, 400);

/// A long list of tappable rows under the guard, and the rows that were
/// actually opened.
Future<List<int>> _pumpList(
  WidgetTester tester, {
  ScrollController? controller,
}) async {
  final tapped = <int>[];
  await tester.pumpWidget(
    CupertinoApp(
      home: ScrollStopGuard(
        child: ListView.builder(
          controller: controller,
          itemCount: 400,
          itemExtent: 60,
          itemBuilder: (context, i) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => tapped.add(i),
            child: Center(child: Text('row $i')),
          ),
        ),
      ),
    ),
  );
  return tapped;
}

void main() {
  testWidgets('the touch that stops a moving list does not open a row', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final tapped = await _pumpList(tester, controller: controller);

    await tester.fling(find.text('row 2'), const Offset(0, -400), 3000);
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, greaterThan(0));

    await tester.tapAt(_middle);
    final stopped = controller.offset;
    await tester.pumpAndSettle();

    expect(tapped, isEmpty);
    // …and the touch did stop the list where the finger landed.
    expect(controller.offset, stopped);
  });

  testWidgets('a tap on a resting list opens the row', (tester) async {
    final tapped = await _pumpList(tester);

    await tester.fling(find.text('row 2'), const Offset(0, -400), 3000);
    await tester.pumpAndSettle();

    await tester.tapAt(_middle);
    await tester.pump();

    expect(tapped, hasLength(1));
  });

  testWidgets('dragging on from the stopping touch still scrolls', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final tapped = await _pumpList(tester, controller: controller);

    await tester.fling(find.text('row 2'), const Offset(0, -400), 3000);
    await tester.pump(const Duration(milliseconds: 100));

    final gesture = await tester.startGesture(_middle);
    await tester.pump(const Duration(milliseconds: 50));
    final stopped = controller.offset;
    // Two moves: the first only crosses the touch slop, which is where a
    // drag starts counting.
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(stopped));
    expect(tapped, isEmpty);
  });

  // The gap the framework leaves: it ignores pointers during a fling, but
  // not while an overscroll springs back — and bounce is where iOS puts a
  // moving list under the finger most often.
  testWidgets('the touch that stops a bounce does not open a row', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final tapped = await _pumpList(tester, controller: controller);

    final pull = await tester.startGesture(_middle);
    for (var i = 0; i < 6; i++) {
      await pull.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await pull.up();
    await tester.pump(const Duration(milliseconds: 30));
    expect(controller.offset, lessThan(0), reason: 'should be bouncing back');

    await tester.tapAt(_middle);
    await tester.pumpAndSettle();

    expect(tapped, isEmpty);
  });
}
