import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/viewer/detail_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

AssetRecord _record({required String localId, bool isFavorite = false}) => AssetRecord(
  localId: localId,
  contentHash: localId,
  platform: 'ios',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  sourceType: AssetSourceType.manualFile,
  sourcePath: '/tmp/$localId.jpg',
  isFavorite: isFavorite,
);

void main() {
  testWidgets('tapping the heart toggles favorite and calls back', (tester) async {
    final record = _record(localId: 'a');
    String? toggledId;

    await tester.pumpWidget(
      _wrap(
        DetailScreen(
          records: [record],
          initialIndex: 0,
          onDelete: (_) async {},
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

  testWidgets('dragging the photo down past the threshold dismisses the screen', (tester) async {
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
                  onDelete: (_) async {},
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
  });

  testWidgets('a small downward drag snaps back instead of dismissing', (tester) async {
    final record = _record(localId: 'a');

    await tester.pumpWidget(
      _wrap(
        DetailScreen(records: [record], initialIndex: 0, onDelete: (_) async {}, onToggleFavorite: (_) async {}),
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
                  onDelete: (_) async {},
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
}
