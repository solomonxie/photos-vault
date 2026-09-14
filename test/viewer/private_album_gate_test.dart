import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/viewer/private_album_gate.dart';
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
  testWidgets('Enter/Create New stay disabled until 4 digits are tapped on the keypad', (tester) async {
    PrivateAlbumChoice? result;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async => result = await showPrivateAlbumPasscodeSheet(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // No system keyboard involved — a numeric keypad, not a text field.
    expect(find.byType(CupertinoTextField), findsNothing);

    final enterButton = tester.widget<CupertinoDialogAction>(
      find.ancestor(of: find.text('Enter'), matching: find.byType(CupertinoDialogAction)),
    );
    expect(enterButton.onPressed, isNull);

    await _tapDigits(tester, '12');
    final stillDisabled = tester.widget<CupertinoDialogAction>(
      find.ancestor(of: find.text('Enter'), matching: find.byType(CupertinoDialogAction)),
    );
    expect(stillDisabled.onPressed, isNull);

    await _tapDigits(tester, '34');
    await tester.tap(find.text('Enter'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.passcode, '1234');
    expect(result!.createNew, isFalse);
  });

  testWidgets('a 5th digit tap is ignored once 4 are entered', (tester) async {
    PrivateAlbumChoice? result;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async => result = await showPrivateAlbumPasscodeSheet(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await _tapDigits(tester, '12345');
    await tester.tap(find.text('Enter'));
    await tester.pumpAndSettle();

    expect(result!.passcode, '1234');
  });

  testWidgets('the delete key removes the last digit', (tester) async {
    PrivateAlbumChoice? result;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async => result = await showPrivateAlbumPasscodeSheet(context),
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
    await tester.tap(find.text('Enter'));
    await tester.pumpAndSettle();

    expect(result!.passcode, '1234');
  });

  testWidgets('Create New reports createNew: true', (tester) async {
    PrivateAlbumChoice? result;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async => result = await showPrivateAlbumPasscodeSheet(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await _tapDigits(tester, '5678');
    await tester.tap(find.text('Create New'));
    await tester.pumpAndSettle();

    expect(result!.passcode, '5678');
    expect(result!.createNew, isTrue);
  });

  testWidgets('Cancel returns null', (tester) async {
    PrivateAlbumChoice? result;
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
