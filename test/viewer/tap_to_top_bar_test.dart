import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/tap_to_top_bar.dart';

void main() {
  testWidgets('a tap on the bar calls back; a button in it keeps its tap', (
    tester,
  ) async {
    var top = 0, button = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          navigationBar: TapToTopBar(
            onTap: () => top++,
            bar: CupertinoNavigationBar(
              middle: const Text('Album'),
              trailing: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => button++,
                child: const Text('Select'),
              ),
            ),
          ),
          child: const SizedBox(),
        ),
      ),
    );
    await tester.tapAt(const Offset(200, 22));
    await tester.tap(find.text('Select'));
    expect((top, button), (1, 1));
  });
}
