import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/settings/bucket_location.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';

const _target = S3BackupTarget(
  id: 't1',
  accessKeyId: 'AKIA',
  secretAccessKey: 'secret',
  region: 'us-east-1',
  bucket: 'my-bucket',
  prefix: '',
);

/// A page with one button, so the helpers get the real navigator and
/// dialogs they push onto.
Widget _wrap(VoidCallback onTap) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: CupertinoPageScaffold(
    child: Center(
      child: CupertinoButton(onPressed: onTap, child: const Text('go')),
    ),
  ),
);

void main() {
  test('the folder an object sits in', () {
    expect(folderPrefixOf('photos/originals/a.jpg'), 'photos/originals/');
    expect(folderPrefixOf('a.jpg'), '');
  });

  testWidgets('opens the presigned URL in the system browser', (tester) async {
    Uri? opened;
    late BuildContext pageContext;
    await tester.pumpWidget(
      _wrap(
        () => openObjectInSystemBrowser(
          pageContext,
          objectKey: 'originals/a.jpg',
          locate: (_) async => _target,
          presign: ({
            required target,
            required key,
            expiresIn = const Duration(minutes: 15),
          }) async => Uri.parse('https://example.com/$key'),
          open: (url) async {
            opened = url;
            return true;
          },
        ),
      ),
    );
    pageContext = tester.element(find.text('go'));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();

    expect(opened, Uri.parse('https://example.com/originals/a.jpg'));
  });

  testWidgets('says so when no bucket has the object', (tester) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      _wrap(
        () => showObjectInBucketBrowser(
          pageContext,
          objectKey: 'originals/a.jpg',
          locate: (_) async => null,
        ),
      ),
    );
    pageContext = tester.element(find.text('go'));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();

    expect(
      find.text("No bucket this phone can reach has this photo's object."),
      findsOneWidget,
    );
  });
}
