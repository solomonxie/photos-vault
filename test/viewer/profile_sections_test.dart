import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/viewer/conversation_screen.dart';
import 'package:photos_vault/viewer/person_page_screen.dart';
import 'package:photos_vault/viewer/person_profile_screen.dart';
import 'package:photos_vault/viewer/profile_previews.dart';
import 'package:photos_vault/viewer/profile_relationships.dart';
import 'package:photos_vault/viewer/profile_summary.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_conversation_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Future<void> _tall(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 3000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

ConversationMessage _msg(int year, String text, String source) {
  final at = DateTime(year, 3, 1);
  return ConversationMessage(
    chat: '$source:1',
    source: source,
    at: at,
    fromMe: false,
    sender: 'Mia',
    text: text,
    kind: 'text',
    hash: ConversationMessage.hashOf('$source:1', at, false, text),
  );
}

PersonRelationship _rel(
  String id,
  RelationshipType type, {
  bool derived = false,
}) => PersonRelationship(
  personId: 'me',
  relatedPersonId: id,
  type: type,
  derived: derived,
);

void main() {
  test('closest first: drawn, then tie, then photos together, then name', () {
    final ranked = rankRelationships(
      [
        _rel('f1', RelationshipType.friend),
        _rel('g', RelationshipType.colleague, derived: true),
        _rel('f2', RelationshipType.friend),
        _rel('s', RelationshipType.spouse),
      ],
      {'f2': 9},
      {'f1': 'A', 'f2': 'B', 'g': 'C', 's': 'D'},
    );
    expect([for (final r in ranked) r.relatedPersonId], ['s', 'f2', 'f1', 'g']);
  });

  test('facts: age, the job held now, the latest place', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final facts = profileFacts(
      l10n,
      detail: PersonDetail(birthDate: DateTime(DateTime.now().year - 30, 1, 1)),
      jobs: [
        PersonHistoryEntry(
          id: 'old',
          personId: 'p',
          category: HistoryCategory.job,
          title: 'Nokia',
          startDate: DateTime(2009),
          endDate: DateTime(2010),
        ),
        const PersonHistoryEntry(
          id: 'now',
          personId: 'p',
          category: HistoryCategory.job,
          title: 'Acme',
          titles: [TimelineEntry(id: 't', title: 'Engineer')],
        ),
      ],
      locations: [
        PersonLocation(
          id: 'a',
          personId: 'p',
          kind: LocationKind.origin,
          place: 'Kunming',
          since: DateTime(1990),
        ),
        PersonLocation(
          id: 'b',
          personId: 'p',
          kind: LocationKind.relocation,
          place: 'Sydney',
          since: DateTime(2016),
        ),
      ],
    );
    expect(facts, ['30 years old', 'Engineer at Acme', 'Sydney']);
  });

  testWidgets('more than twenty relationships get a search and filters', (
    tester,
  ) async {
    await _tall(tester);
    final store = FakePersonStore();
    final mia = await store.create(name: 'Mia');
    for (var i = 0; i < 22; i++) {
      final p = await store.create(name: 'Friend $i');
      await store.addRelationship(
        mia.id,
        p.id,
        i == 0 ? RelationshipType.sibling : RelationshipType.friend,
        scope: PersonScope.open,
      );
    }
    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: store,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profileTab:people')));
    await tester.pumpAndSettle();

    final search = find.byKey(const ValueKey('relationshipSearch'));
    expect(search, findsOneWidget);
    await tester.enterText(search, 'friend 13');
    await tester.pump();
    expect(find.text('Friend 13'), findsOneWidget);
    // Fuzzy finds the rest of the Friends too, but the one typed leads.
    expect(
      tester.getTopLeft(find.text('Friend 13')).dy,
      lessThan(tester.getTopLeft(find.text('Friend 12')).dy),
    );

    await tester.enterText(search, '');
    await tester.pump();
    await tester.tap(find.text('Sibling 1'));
    await tester.pump();
    expect(find.widgetWithText(CupertinoListTile, 'Friend 0'), findsOneWidget);
    expect(find.widgetWithText(CupertinoListTile, 'Friend 5'), findsNothing);
  });

  testWidgets('the bio sits in the top card, above the tabs', (tester) async {
    await _tall(tester);
    final store = FakePersonStore();
    final mia = await store.create(name: 'Mia');
    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: store,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('profileSummary')),
        matching: find.byKey(const ValueKey('profileBio')),
      ),
      findsOneWidget,
    );
    expect(find.byKey(profileSectionHeaderKey('About')), findsNothing);
    expect(find.text('No bio yet.'), findsOneWidget);
  });

  testWidgets('the message count at the top opens the chats page', (
    tester,
  ) async {
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    final chats = FakeConversationStore();
    await chats.insert(mia.id, [
      _msg(2015, 'old one', 'whatsapp'),
      _msg(2019, 'middle', 'imessage'),
      _msg(2024, 'see you soon', 'whatsapp'),
    ]);
    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: people,
          assetRecordStore: FakeAssetRecordStore(),
          conversationStore: chats,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profileCountChats')), findsOneWidget);
    expect(find.text('3 messages'), findsOneWidget);
    // No Chats section on the profile: the count is the one way in.
    expect(find.byKey(profileSectionHeaderKey('Chats')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('profileCountChats')));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationScreen), findsOneWidget);
    expect(find.text('see you soon'), findsOneWidget);
  });

  testWidgets('the job timeline folds projects until tapped', (tester) async {
    await tester.pumpWidget(
      _wrap(
        CupertinoPageScaffold(
          child: HistoryTimeline(
            onOpen: (_) {},
            entries: [
              PersonHistoryEntry(
                id: 'j',
                personId: 'p',
                category: HistoryCategory.job,
                title: 'Acme',
                startDate: DateTime(2015),
                projects: const [CareerProject(id: 'c', name: 'Rocket')],
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('2015\nPresent'), findsOneWidget);
    expect(find.text('• Rocket'), findsNothing);
    await tester.tap(find.textContaining('1 project'));
    await tester.pump();
    expect(find.text('• Rocket'), findsOneWidget);
  });

  testWidgets('a person page leads with their facts and opens the profile', (
    tester,
  ) async {
    final store = FakePersonStore();
    final mia = await store.create(name: 'Mia');
    await store.addLocation(
      PersonLocation(
        id: 'l',
        personId: mia.id,
        kind: LocationKind.origin,
        place: 'Sydney',
        since: DateTime(2016),
      ),
      scope: PersonScope.open,
    );
    await tester.pumpWidget(
      _wrap(
        PersonPageScreen(
          person: mia,
          personStore: store,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sydney'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('personPageProfilePill')));
    await tester.pumpAndSettle();
    expect(find.byType(PersonProfileScreen), findsOneWidget);
  });
}
