import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/resize_photos.dart';

AssetRecord _record(int i) => AssetRecord(
  localId: 'manual:$i',
  contentHash: '$i',
  platform: 'test',
  sourceType: AssetSourceType.manualFile,
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
);

void main() {
  Future<List<List<AssetRecord>>> pump(WidgetTester tester, int count) async {
    final replaced = <List<AssetRecord>>[];
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => CupertinoButton(
            child: const Text('go'),
            onPressed: () => resizePhotos(
              context,
              records: [for (var i = 0; i < count; i++) _record(i)],
              readBytes: (_) async => null,
              saveCopy: (source, bytes, extension) async => source,
              replaceOriginals: (originals) async => replaced.add(originals),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return replaced;
  }

  testWidgets('past ten photos, Save as New does nothing', (tester) async {
    await pump(tester, resizeNewCopyLimit + 1);
    expect(find.textContaining('up to 10'), findsOneWidget);

    await tester.tap(find.text('Save as New'));
    await tester.pumpAndSettle();
    expect(find.text('Save as New'), findsOneWidget);
  });

  testWidgets('nothing resized replaces nothing', (tester) async {
    final replaced = await pump(tester, 2);
    expect(find.textContaining('up to 10'), findsNothing);

    await tester.tap(find.text('Replace Originals'));
    await tester.pumpAndSettle();

    expect(find.textContaining('could be resized'), findsOneWidget);
    expect(replaced, isEmpty);
  });
}
