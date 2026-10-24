import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/viewer/conversation_screen.dart';

import '../support/fake_conversation_store.dart';

void main() {
  testWidgets('newest at the bottom; older pages load on scrolling up', (
    tester,
  ) async {
    final store = FakeConversationStore();
    final start = DateTime(2020);
    await store.insert('p', [
      for (var i = 0; i < 450; i++)
        ConversationMessage(
          chat: 'qq:1',
          source: 'qq',
          at: start.add(Duration(minutes: i)),
          fromMe: i.isEven,
          sender: '',
          text: 'msg $i',
          kind: 'text',
          hash: 'h${i.toString().padLeft(4, '0')}',
        ),
    ]);
    final now = DateTime.now();
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConversationScreen(
          person: Person(id: 'p', name: 'Mia', createdAt: now, updatedAt: now),
          store: store,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('msg 449'), findsOne);
    expect(find.text('msg 0'), findsNothing);
    // 449 minutes after midnight, on its bubble.
    expect(
      find.text(
        DateFormat.jm().format(start.add(const Duration(minutes: 449))),
      ),
      findsOne,
    );

    // To the top, again as each older page lands.
    for (var i = 0; i < 10 && find.text('msg 0').evaluate().isEmpty; i++) {
      final list = tester
          .state<ScrollableState>(find.byType(Scrollable).last)
          .position;
      list.jumpTo(list.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(find.text('msg 0'), findsOne);

    await tester.enterText(find.byType(CupertinoSearchTextField), 'msg 12');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('msg 12'), findsOne);
    expect(find.text('msg 120'), findsOne);
    expect(
      find.text(
        DateFormat.yMMMd().add_jm().format(
          start.add(const Duration(minutes: 120)),
        ),
      ),
      findsOne,
    );
  });
}
