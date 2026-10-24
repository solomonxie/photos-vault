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
  testWidgets('same name attaches by default, similar waits, nobody is '
      'never added', (tester) async {
    final people = FakePersonStore();
    final liu = await people.create(name: '刘越');
    final daniel = await people.create(name: 'Daniel Lee');
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

    // Similar first, then the default attach, then nobody.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('conversation-row-0')),
        matching: find.text('Daniel'),
      ),
      findsOne,
    );
    expect(
      find.text('Attaching to the person with this name — tap to change'),
      findsOne,
    );
    expect(find.text('Not in People — tap to choose someone'), findsOne);
    expect(find.byKey(const ValueKey('importNeedsChoice')), findsOne);
    final apply = find.byKey(const ValueKey('conversationsApply'));
    expect(tester.widget<CupertinoButton>(apply).onPressed, isNull);

    // Nobody stays out unless asked; asked, they're a new person.
    await tester.tap(find.text('Stranger'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Not in People — tap to choose someone'), findsOne);

    await tester.tap(find.byKey(const ValueKey('conversation-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('importMergeInto-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('importNeedsChoice')), findsNothing);
    expect(find.text('Import for 2 people'), findsOne);

    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(await conversations.countsByPerson(), {liu.id: 2, daniel.id: 1});
    expect(
      (await people.listAll()).length,
      2,
      reason: 'Stranger was not added',
    );
    expect(find.byKey(const ValueKey('conversationsDone')), findsOne);
    expect(
      find.text('3 messages added for 2 people; 0 already here.'),
      findsOne,
    );
  });

  testWidgets('a rename that matches someone attaches; re-import adds none', (
    tester,
  ) async {
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    final conversations = FakeConversationStore();
    await tester.pumpWidget(
      _wrap(
        ConversationImportScreen(
          personStore: people,
          conversationStore: conversations,
          pickFiles: () async => ['a.jsonl'],
          readFiles: (_) async => readConversationLines(
            [_line('Stranger', 4, 'd'), _line('Stranger', 5, 'e')].join('\n'),
          ),
        ),
      ),
    );
    for (var round = 0; round < 2; round++) {
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
    }
    expect(await conversations.countsByPerson(), {mia.id: 2});
    expect(
      find.text('0 messages added for 1 person; 2 already here.'),
      findsOne,
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
