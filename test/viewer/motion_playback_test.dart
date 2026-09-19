import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/motion_playback.dart';

import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  test('hold is the default, and a choice outlives the app', () async {
    final store = FakeAssetRecordStore();

    final first = MotionPlaybackSetting(settings: store);
    await first.load();
    expect(first.mode.value, MotionPlayMode.hold);

    await first.set(MotionPlayMode.loop);

    // A fresh one, as if the app had been restarted.
    final second = MotionPlaybackSetting(settings: store);
    await second.load();
    expect(second.mode.value, MotionPlayMode.loop);
  });

  test('an unreadable setting falls back to a working viewer', () async {
    final setting = MotionPlaybackSetting(settings: _BrokenStore());

    await setting.load();

    expect(setting.mode.value, MotionPlayMode.hold);
  });

  testWidgets('the bar offers all three modes and marks the current one', (
    tester,
  ) async {
    var picked = MotionPlayMode.hold;
    await tester.pumpWidget(
      _wrap(
        Center(
          child: MotionPlayModeBar(
            mode: MotionPlayMode.loop,
            onChanged: (value) => picked = value,
          ),
        ),
      ),
    );

    for (final mode in MotionPlayMode.values) {
      expect(find.byIcon(MotionPlayModeBar.iconOf(mode)), findsOneWidget);
    }

    await tester.tap(
      find.byIcon(MotionPlayModeBar.iconOf(MotionPlayMode.still)),
    );
    expect(picked, MotionPlayMode.still);
  });
}

/// A store whose app-state table isn't there — a widget test with no
/// `sqflite` behind it.
class _BrokenStore extends FakeAssetRecordStore {
  @override
  Future<String?> getAppState(String key) async => throw StateError('no db');
}
