import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/settings/bucket_object_preview_screen.dart';
import 'package:bring_your_own_photos/settings/s3_backup_target.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

const _target = S3BackupTarget(
  id: 't1',
  accessKeyId: 'AKIA',
  secretAccessKey: 'secret',
  region: 'us-east-1',
  bucket: 'my-bucket',
  prefix: '',
);

void main() {
  testWidgets('shows the object filename in the app bar', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BucketObjectPreviewScreen(
          target: _target,
          objectKey: 'originals/vacation.jpg',
          presignGetUrl: ({required target, required key}) async =>
              Uri.parse('https://example.com/$key'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('vacation.jpg'), findsOneWidget);
  });

  testWidgets(
    'a non-image key offers Open Externally instead of an inline preview',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          BucketObjectPreviewScreen(
            target: _target,
            objectKey: 'originals/notes.txt',
            presignGetUrl: ({required target, required key}) async =>
                Uri.parse('https://example.com/$key'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text("Can't preview this file type."), findsOneWidget);
      expect(find.text('Open Externally'), findsOneWidget);
    },
  );

  testWidgets('shows the presign error inline when it fails', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BucketObjectPreviewScreen(
          target: _target,
          objectKey: 'originals/a.jpg',
          presignGetUrl: ({required target, required key}) async =>
              throw Exception('no credentials'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('no credentials'), findsOneWidget);
  });
}
