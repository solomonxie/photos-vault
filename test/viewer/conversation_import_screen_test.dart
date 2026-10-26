import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/search_picker_sheet.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/viewer/conversation_import_screen.dart';

import '../support/fake_conversation_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

String _line(String person, int minute, String text) =>
    '{"person":"$person","source":"qq","chat":"qq:$person",'
    '"at":"2020-01-01T10:${minute.toString().padLeft(2, '0')}:00",'
    '"from_me":false,"sender":"$person","text":"$text","kind":"text"}';

final _file = [
  _line('刘越', 1, 'a'),
  _line('刘越', 2, 'b'),
  _line('Daniel', 3, 'c'),
  _line('Stranger', 4, 'd'),
].join('\n');

void main() {
  testWidgets('a row marks voice and pictures in what it would bring', (
    tester,
  ) async {
    String line(String person, String kind) =>
        '{"person":"$person","chat":"wechat:$person",'
        '"at":"2020-01-01T10:00:00","kind":"$kind"}';
    await tester.pumpWidget(
      _wrap(
        ConversationImportScreen(
          personStore: FakePersonStore(),
          conversationStore: FakeConversationStore(),
          pickOnOpen: true,
          pickFiles: () async => ['a.jsonl'],
          readFiles: (_) async => readConversationLines(
            [
              line('Mia', 'voice'),
              line('Mia', 'image'),
              line('Mia', 'text'),
              line('Zoe', 'text'),
            ].join('\n'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-voice-0')), findsOne);
    expect(find.byKey(const ValueKey('conversation-images-0')), findsOne);
    expect(find.byKey(const ValueKey('conversation-voice-1')), findsNothing);
    expect(find.byKey(const ValueKey('conversation-images-1')), findsNothing);
  });

  testWidgets('same name and closest match attach by default, nobody is '
      'never added', (tester) async {
    final people = FakePersonStore();
    final liu = await people.create(name: '刘越');
    final daniel = await people.create(name: 'Daniel Lee');
    await people.create(name: 'Daniel Alexander');
    final conversations = FakeConversationStore();
    await tester.pumpWidget(
      _wrap(
        ConversationImportScreen(
          personStore: people,
          conversationStore: conversations,
          pickOnOpen: true,
          pickFiles: () async => ['a.jsonl', 'b.zip'],
          readFiles: (paths) async {
            expect(paths, ['a.jsonl', 'b.zip']);
            return readConversationLines(_file);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Closest guess first, then the same-name attach, then nobody.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('conversation-row-0')),
        matching: find.text('Daniel'),
      ),
      findsOne,
    );
    expect(
      find.text('Closest match: Daniel Lee — tap to choose from 1 more'),
      findsOne,
    );
    expect(
      find.text('Attaching to the person with this name — tap to change'),
      findsOne,
    );
    expect(find.text('Not in People — tap to choose someone'), findsOne);
    expect(find.byKey(const ValueKey('importNeedsChoice')), findsNothing);
    expect(find.text('Import for 2 people'), findsOne);

    // Nobody stays out unless asked; asked, they're a new person.
    await tester.tap(find.text('Stranger'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Not in People — tap to choose someone'), findsOne);

    await tester.tap(find.byKey(const ValueKey('conversationsApply')));
    await tester.pumpAndSettle();
    expect(await conversations.countsByPerson(), {liu.id: 2, daniel.id: 1});
    expect(
      (await people.listAll()).length,
      3,
      reason: 'Stranger was not added',
    );
    expect(find.byKey(const ValueKey('conversationsDone')), findsOne);
    expect(
      find.text('3 messages added for 2 people; 0 already here.'),
      findsOne,
    );
    final logged = (await people.changesOf(liu.id)).first;
    expect(logged.kind, 'imported');
    expect(jsonDecode(logged.after!), {
      'source': 'chats',
      'count': 2,
      'sources': ['qq'],
    });
  });

  testWidgets('a choice is remembered: the next import attaches by name, '
      'and by chat under another name', (tester) async {
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    final conversations = FakeConversationStore();
    var file = [_line('Stranger', 4, 'd')].join('\n');
    await tester.pumpWidget(
      _wrap(
        ConversationImportScreen(
          personStore: people,
          conversationStore: conversations,
          pickFiles: () async => ['a.jsonl'],
          readFiles: (_) async => readConversationLines(file),
        ),
      ),
    );
    Future<void> pick() async {
      await tester.tap(find.byKey(const ValueKey('conversationsChooseFiles')));
      await tester.pumpAndSettle();
    }

    await pick();
    await tester.tap(find.byKey(const ValueKey('conversation-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('importRename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(searchPickerFieldKey), 'Mia');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conversationsApply')));
    await tester.pumpAndSettle();
    expect(
      [for (final k in await people.knownAsOf(mia.id)) k.value],
      ['Stranger', 'qq:Stranger'],
    );

    // The same name again: theirs, nothing to choose.
    file = _line('Stranger', 6, 'f');
    await pick();
    expect(find.text('Remembered: Mia'), findsOne);
    await tester.tap(find.byKey(const ValueKey('conversationsApply')));
    await tester.pumpAndSettle();

    // Another name on the same chat: still theirs.
    file =
        '{"person":"S.","source":"qq","chat":"qq:Stranger",'
        '"at":"2020-01-01T11:00:00","text":"g"}';
    await pick();
    expect(find.text('Remembered: Mia'), findsOne);
    await tester.tap(find.byKey(const ValueKey('conversationsApply')));
    await tester.pumpAndSettle();
    expect(await conversations.countsByPerson(), {mia.id: 3});
    expect(
      await people.knownAsOf(mia.id),
      hasLength(3),
      reason: '"S." joins; the chat is not added twice',
    );
  });

  testWidgets('a rename that matches someone attaches; re-import shows '
      'nothing already here', (tester) async {
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    final conversations = FakeConversationStore();
    var lines = [_line('Stranger', 4, 'd'), _line('Stranger', 5, 'e')];
    await tester.pumpWidget(
      _wrap(
        ConversationImportScreen(
          personStore: people,
          conversationStore: conversations,
          pickFiles: () async => ['a.jsonl'],
          readFiles: (_) async => readConversationLines(lines.join('\n')),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('conversationsChooseFiles')));
    await tester.pumpAndSettle();
    expect(find.text('Import for 0 people'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('conversation-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('importRename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(searchPickerFieldKey), 'Mia');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conversationsApply')));
    await tester.pumpAndSettle();
    expect(await conversations.countsByPerson(), {mia.id: 2});

    // The same file again: nothing to review.
    await tester.tap(find.byKey(const ValueKey('conversationsChooseFiles')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-row-0')), findsNothing);
    expect(
      find.text('Nothing new: all 2 messages are already imported.'),
      findsOne,
    );

    // One more message: only it comes up, the rest counted as here.
    lines = [...lines, _line('Stranger', 6, 'f')];
    await tester.tap(find.byKey(const ValueKey('conversationsChooseFiles')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-row-0')), findsOne);
    expect(find.byKey(const ValueKey('conversation-row-1')), findsNothing);
    expect(
      find.textContaining('2 messages already imported, not shown'),
      findsOne,
    );
    expect(
      [
        for (final c in await people.changesOf(mia.id))
          if (c.kind == 'imported') c,
      ].length,
      1,
    );
  });

  testWidgets('a name nobody has can come in as a new person', (tester) async {
    final people = FakePersonStore();
    final conversations = FakeConversationStore();
    await tester.pumpWidget(
      _wrap(
        ConversationImportScreen(
          personStore: people,
          conversationStore: conversations,
          pickOnOpen: true,
          pickFiles: () async => ['a.jsonl'],
          readFiles: (_) async => readConversationLines(
            '{"person":"Zed","source":"qq","chat":"qq:3","at":"2020-01-03T09:00:00","from_me":false,"sender":"Zed","text":"yo","kind":"text"}',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zed'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('importAsNew')));
    await tester.pumpAndSettle();
    expect(find.text('New person “Zed”'), findsOne);
    await tester.tap(find.byKey(const ValueKey('conversationsApply')));
    await tester.pumpAndSettle();
    final zed = (await people.listAll()).single;
    expect(zed.name, 'Zed');
    expect(await conversations.countsByPerson(), {zed.id: 1});
  });
}
