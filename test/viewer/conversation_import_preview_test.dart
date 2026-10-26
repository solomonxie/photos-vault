import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/viewer/conversation_import_screen.dart';

import '../support/fake_conversation_store.dart';
import '../support/fake_person_store.dart';

// 1×1 transparent PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  testWidgets('the preview plays a voice clip and shows a picture', (
    tester,
  ) async {
    final stage = Directory.systemTemp.createTempSync('voice');
    addTearDown(() => stage.deleteSync(recursive: true));
    final export = readConversationLines(
      [
        '{"person":"Mia","chat":"wechat:mia","at":"2021-01-01T10:00:00",'
            '"kind":"voice","voice":"${base64Encode([1, 2, 3])}",'
            '"voice_ms":4200}',
        '{"person":"Mia","chat":"wechat:mia","at":"2021-01-01T10:01:00",'
            '"kind":"image","thumb":"$_png"}',
      ].join('\n'),
      stageDir: stage.path,
    );
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConversationImportScreen(
          personStore: FakePersonStore(),
          conversationStore: FakeConversationStore(),
          pickOnOpen: true,
          pickFiles: () async => ['a.jsonl'],
          readFiles: (_) async => export,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conversation-preview-0')));
    await tester.pumpAndSettle();

    final voice = export.people.single.messages
        .firstWhere((m) => m.kind == 'voice')
        .voice!;
    expect(find.byKey(ValueKey('voice:$voice')), findsOne);
    expect(find.text('5″'), findsOne);
    expect(
      find.byWidgetPredicate((w) => w is Image && w.width == 160),
      findsOne,
    );
  });
}
