import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/private_album_gate.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Future<void> _tapDigits(WidgetTester tester, String digits) async {
  for (final digit in digits.split('')) {
    await tester.tap(find.text(digit));
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'the 4th digit submits automatically — no Enter/Create/Cancel to tap',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => CupertinoButton(
              onPressed: () async =>
                  result = await showPrivateAlbumPasscodeSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // No system keyboard involved — a numeric keypad, not a text field.
      expect(find.byType(CupertinoTextField), findsNothing);
      // One way out — no Enter/Create New to choose between.
      expect(find.text('Cancel'), findsOneWidget);

      await _tapDigits(tester, '123');
      expect(result, isNull);

      await _tapDigits(tester, '4');
      await tester.pumpAndSettle();

      expect(result, '1234');
    },
  );

  testWidgets('a 5th digit tap is ignored once 4 are entered', (tester) async {
    String? result;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async =>
                result = await showPrivateAlbumPasscodeSheet(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await _tapDigits(tester, '12345');
    await tester.pumpAndSettle();

    expect(result, '1234');
  });

  testWidgets('the delete key removes the last digit', (tester) async {
    String? result;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async =>
                result = await showPrivateAlbumPasscodeSheet(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await _tapDigits(tester, '129');
    await tester.tap(find.byIcon(CupertinoIcons.delete_left));
    await tester.pump();
    await _tapDigits(tester, '34');
    await tester.pumpAndSettle();

    expect(result, '1234');
  });

  testWidgets('Cancel returns null', (tester) async {
    String? result;
    var called = false;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async {
              result = await showPrivateAlbumPasscodeSheet(context);
              called = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(result, isNull);
  });
}
