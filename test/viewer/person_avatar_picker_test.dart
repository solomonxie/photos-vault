import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/viewer/person_avatar_picker.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

void main() {
  testWidgets('a face of theirs picks the photo and its crop together', (
    tester,
  ) async {
    final photos = FakeAssetRecordStore();
    await photos.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    await people.addAssets(mia.id, ['a']);
    final analysis = FakeAiAnalysisStore();
    const face = FaceRect(0.2, 0.2, 0.3, 0.3);
    await analysis.saveDescriptor(
      localId: 'a',
      face: face,
      descriptor: FaceDescriptor(
        vector: Float32List.fromList([1, 0]),
        revision: 4,
      ),
      personId: mia.id,
    );

    ({String localId, FaceRect? face})? chosen;
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async =>
                chosen = await Navigator.of(context)
                    .push<({String localId, FaceRect? face})>(
                      CupertinoPageRoute(
                        builder: (_) => PersonAvatarPicker(
                          person: mia,
                          personStore: people,
                          assetRecordStore: photos,
                          aiAnalysisStore: analysis,
                        ),
                      ),
                    ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('avatarFace-a')));
    await tester.pumpAndSettle();
    expect(chosen?.localId, 'a');
    expect(chosen?.face, face);
  });
}
