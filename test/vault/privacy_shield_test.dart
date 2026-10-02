import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/vault/private_lifecycle.dart';

class _Private extends StatefulWidget {
  const _Private();

  @override
  State<_Private> createState() => _PrivateState();
}

class _PrivateState extends State<_Private>
    with WidgetsBindingObserver, PrivateScreenLifecycle {
  @override
  Widget build(BuildContext context) => const Text('hidden photo');
}

void main() {
  const cover = ValueKey('privacyCover');

  Future<void> pump(WidgetTester tester, Widget home) => tester.pumpWidget(
    CupertinoApp(
      builder: (context, child) => PrivacyShield(child: child!),
      home: home,
    ),
  );

  testWidgets('leaving the app covers everything above a private screen', (
    tester,
  ) async {
    await pump(tester, const _Private());
    expect(find.byKey(cover), findsNothing);

    // A photo opened on top of the album: the cover has to be over it too.
    final context = tester.element(find.text('hidden photo'));
    Navigator.of(context)
        .push(CupertinoPageRoute<void>(builder: (_) => const Text('detail')));
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byKey(cover), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byKey(cover), findsNothing);
  });

  testWidgets('with no private screen open, nothing is covered', (
    tester,
  ) async {
    await pump(tester, const Text('library'));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byKey(cover), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
