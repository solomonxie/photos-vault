import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/viewer/person_graph_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('shows the empty state with fewer than 2 people', (tester) async {
    final personStore = FakePersonStore();
    await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonGraphScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Add relationships to see the graph.'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets(
    'is zoomable/pannable via InteractiveViewer once there are relationships',
    (tester) async {
      final personStore = FakePersonStore();
      final mia = await personStore.create(name: 'Mia');
      final daniel = await personStore.create(name: 'Daniel');
      await personStore.addRelationship(
        mia.id,
        daniel.id,
        RelationshipType.friend,
      );

      await tester.pumpWidget(
        _wrap(
          PersonGraphScreen(
            personStore: personStore,
            assetRecordStore: FakeAssetRecordStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsOneWidget);
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(viewer.minScale, lessThan(1));
      expect(viewer.maxScale, greaterThan(1));
    },
  );
}
