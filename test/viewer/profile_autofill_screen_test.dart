import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/ai_ask_service.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/viewer/profile_autofill_screen.dart';

import '../support/fake_person_store.dart';

class _FakeAsk implements AiAskService {
  _FakeAsk(this.reply);
  final String reply;
  String? prompt;

  @override
  Future<String> ask({
    required String question,
    String context = '',
    Uint8List? image,
  }) async {
    prompt = question;
    return reply;
  }
}

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

const _reply = '''
{"suggestions":[
  {"target":"job","label":"Acme Ltd","value":"Engineer","detail":"2015-2019"},
  {"target":"place","label":"Kyoto"},
  {"target":"tag","label":"Organised"}
]}
''';

void main() {
  testWidgets('nothing is written until something is accepted', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final service = _FakeAsk(_reply);

    await tester.pumpWidget(
      _wrap(
        ProfileAutofillScreen(
          person: mia,
          personStore: personStore,
          detail: PersonDetail.empty,
          service: service,
          pickFile: () async => (
            name: 'cv.txt',
            bytes: utf8.encode('Mia worked at Acme.'),
            path: null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();

    // Three found, none accepted, nothing saved.
    expect(find.byKey(const ValueKey('suggestion-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('suggestion-2')), findsOneWidget);
    expect(find.text('Nothing selected'), findsOneWidget);
    expect(await personStore.historyFor(mia.id, HistoryCategory.job), isEmpty);
    // And the document went to the vendor, not just the question.
    expect(service.prompt, contains('Mia worked at Acme.'));
  });

  testWidgets('accepting some writes only those', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        ProfileAutofillScreen(
          person: mia,
          personStore: personStore,
          detail: PersonDetail.empty,
          service: _FakeAsk(_reply),
          pickFile: () async =>
              (name: 'cv.txt', bytes: utf8.encode('x'), path: null),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();

    // The job, and the tag. Not the place.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('suggestion-0')),
        matching: find.byType(CupertinoSwitch),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('suggestion-2')),
        matching: find.byType(CupertinoSwitch),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add 2 items'));
    await tester.pumpAndSettle();

    final jobs = await personStore.historyFor(mia.id, HistoryCategory.job);
    expect(jobs.single.title, 'Acme Ltd');
    // Lower-cased on the way in, same as a tag typed by hand.
    expect((await personStore.detailFor(mia.id)).impression.tags, [
      'organised',
    ]);
    expect(await personStore.locationsFor(mia.id), isEmpty);
  });

  testWidgets('accept all takes the lot', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        ProfileAutofillScreen(
          person: mia,
          personStore: personStore,
          detail: PersonDetail.empty,
          service: _FakeAsk(_reply),
          pickFile: () async =>
              (name: 'cv.txt', bytes: utf8.encode('x'), path: null),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept all'));
    await tester.pumpAndSettle();
    expect(find.text('Add 3 items'), findsOneWidget);

    await tester.tap(find.text('Reject all'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing selected'), findsOneWidget);
  });

  testWidgets('a format with no reader says so and asks nobody', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final service = _FakeAsk(_reply);

    await tester.pumpWidget(
      _wrap(
        ProfileAutofillScreen(
          person: mia,
          personStore: personStore,
          detail: PersonDetail.empty,
          service: service,
          // A PDF header.
          pickFile: () async => (
            name: 'notes.rtf',
            bytes: [0x7B, 0x5C, 0x72, 0x74, 0x66, 0x80, 0xFF],
            path: null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();

    expect(find.textContaining("can't be read"), findsOneWidget);
    // Nothing was sent, so nothing was charged for.
    expect(service.prompt, isNull);
  });
}
