import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/viewer/conversation_screen.dart';

import '../support/fake_conversation_store.dart';

// 1×1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('a voice message plays and shows its length', (tester) async {
    final store = FakeConversationStore();
    await store.insert('p', [
      ConversationMessage(
        chat: 'wechat:1',
        source: 'wechat',
        at: DateTime(2020),
        fromMe: false,
        sender: '',
        text: '',
        kind: 'voice',
        hash: 'h1',
        voice: 'h1.mp3',
        voiceMs: 4200,
      ),
    ]);
    final played = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('byo.photos/voice_clip'),
      (call) async {
        played.add(call.method);
        return call.method == 'play' ? 4.2 : null;
      },
    );
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
    expect(find.text('5″'), findsOne);
    expect(find.byIcon(CupertinoIcons.play_circle_fill), findsOne);
  });

  testWidgets('a picture opens full; a tap or a pull down closes it', (
    tester,
  ) async {
    final store = FakeConversationStore();
    await store.insert('p', [
      ConversationMessage(
        chat: 'qq:1',
        source: 'qq',
        at: DateTime(2020),
        fromMe: true,
        sender: '',
        text: '',
        kind: 'image',
        hash: 'h1',
        thumb: _png,
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
    final full = find.byKey(const ValueKey('chatImageFull'));
    // A test never decodes the picture, so it lays out at no size: the
    // tap is called rather than aimed.
    void openThumb() => tester
        .widget<GestureDetector>(
          find
              .ancestor(
                of: find.byWidgetPredicate((w) => w is Image && w.width == 160),
                matching: find.byType(GestureDetector),
              )
              .first,
        )
        .onTap!();
    openThumb();
    await tester.pumpAndSettle();
    expect(full, findsOne);
    await tester.tap(full);
    await tester.pumpAndSettle();
    expect(full, findsNothing);

    openThumb();
    await tester.pumpAndSettle();
    await tester.drag(full, const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(full, findsOne, reason: 'a short pull springs back');
    await tester.drag(full, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(full, findsNothing);
  });

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
