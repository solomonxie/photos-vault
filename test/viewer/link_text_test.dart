import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/link_text.dart';

List<String> _links(WidgetTester tester) {
  final rich = tester.widget<Text>(find.byType(Text)).textSpan! as TextSpan;
  return [
    for (final span in rich.children!.cast<TextSpan>())
      if (span.recognizer is TapGestureRecognizer) span.text!,
  ];
}

void main() {
  testWidgets('links are found and sentence punctuation is left out', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CupertinoApp(
        home: LinkText(
          'See https://example.com/a?b=1, and www.kyoto.jp. Also (https://x.io/y).',
        ),
      ),
    );
    expect(_links(tester), [
      'https://example.com/a?b=1',
      'www.kyoto.jp',
      'https://x.io/y',
    ]);
  });

  testWidgets('plain text has nothing to tap', (tester) async {
    await tester.pumpWidget(
      const CupertinoApp(home: LinkText('Temples on day two')),
    );
    expect(_links(tester), isEmpty);
  });
}
