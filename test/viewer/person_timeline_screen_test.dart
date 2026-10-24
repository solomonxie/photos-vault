import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/viewer/person_timeline_screen.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_conversation_store.dart';
import '../support/fake_person_store.dart';

void main() {
  testWidgets('events, a month of photos and of messages, newest first', (
    tester,
  ) async {
    final photos = FakeAssetRecordStore();
    await photos.upsert(
      localId: 'a',
      contentHash: 'a',
      platform: 'ios',
      createdAt: DateTime(2021, 5, 3),
    );
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    await people.addAssets(mia.id, ['a']);
    await people.saveEvent(
      PersonEvent(
        id: 'e',
        personId: mia.id,
        type: PersonEventType.firstMet,
        at: DateTime(2010, 9, 1),
      ),
      scope: PersonScope.open,
    );
    final chats = FakeConversationStore();
    await chats.insert(mia.id, [
      for (final d in [1, 2])
        ConversationMessage(
          chat: 'qq:1',
          source: 'qq',
          at: DateTime(2015, 3, d),
          fromMe: true,
          sender: '',
          text: 'hi $d',
          kind: 'text',
          hash: 'h$d',
        ),
    ]);
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: PersonTimelineScreen(
          person: mia,
          personStore: people,
          assetRecordStore: photos,
          conversationStore: chats,
        ),
      ),
    );
    await tester.pumpAndSettle();

    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(find.text('1 photo'), findsOneWidget);
    expect(find.text('2 messages'), findsOneWidget);
    expect(find.text('First met'), findsOneWidget);
    expect(y('1 photo'), lessThan(y('2 messages')));
    expect(y('2 messages'), lessThan(y('First met')));
  });
}
