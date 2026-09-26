import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/ai_ask_service.dart';
import 'package:photos_vault/viewer/ask_ai_screen.dart';

class _FakeAsk implements AiAskService {
  _FakeAsk({this.throws});

  static const answer = 'Because of the light.';
  final Object? throws;
  String? question;
  String? context;
  Uint8List? image;

  @override
  Future<String> ask({
    required String question,
    String context = '',
    Uint8List? image,
  }) async {
    this.question = question;
    this.context = context;
    this.image = image;
    if (throws case final error?) throw error;
    return answer;
  }
}

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('a question goes with its context, and the answer comes back', (
    tester,
  ) async {
    final service = _FakeAsk();

    await tester.pumpWidget(
      _wrap(
        AskAiScreen(subject: 'Mia', context: 'Name: Mia', service: service),
      ),
    );
    await tester.pumpAndSettle();

    // What will be sent is on screen before anything is sent.
    expect(find.text('Name: Mia'), findsOneWidget);

    await tester.enterText(
      find.byType(CupertinoTextField).first,
      'Who is she?',
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();

    expect(service.question, 'Who is she?');
    expect(service.context, 'Name: Mia');
    // No picture for a question about a person: their profile is words, and
    // uploading a photo to answer it would be paying for nothing.
    expect(service.image, isNull);
    expect(find.text('Because of the light.'), findsOneWidget);
  });

  testWidgets('a failure is reported rather than swallowed', (tester) async {
    final service = _FakeAsk(throws: Exception('OpenAI request failed (401)'));

    await tester.pumpWidget(
      _wrap(AskAiScreen(subject: 'Mia', service: service)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(CupertinoTextField).first, 'Why?');
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();

    expect(find.textContaining('401'), findsOneWidget);
  });

  testWidgets('an empty question asks nothing', (tester) async {
    final service = _FakeAsk();

    await tester.pumpWidget(
      _wrap(AskAiScreen(subject: 'Mia', service: service)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();

    expect(service.question, isNull);
  });

  testWidgets('the resolution choice is only offered for a photo', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(AskAiScreen(subject: 'Mia', service: _FakeAsk())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Small (cheapest)'), findsNothing);

    await tester.pumpWidget(
      _wrap(
        AskAiScreen(
          key: const ValueKey('photo'),
          subject: 'A photo',
          imageBytes: () async => null,
          service: _FakeAsk(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Small by default: tokens are charged by pixels, and most questions
    // about a photo are answered as well by a thumbnail.
    expect(find.text('Small (cheapest)'), findsOneWidget);
  });

  test('each resolution names its own longest edge', () {
    expect(maxEdgeFor(AskAiResolution.small), 512);
    expect(maxEdgeFor(AskAiResolution.medium), 1024);
    expect(maxEdgeFor(AskAiResolution.full), isNull);
  });
}
