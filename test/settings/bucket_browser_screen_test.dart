import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/settings/bucket_browser_screen.dart';
import 'package:bring_your_own_photos/settings/bucket_object_preview_screen.dart';
import 'package:bring_your_own_photos/settings/s3_backup_target.dart';
import 'package:bring_your_own_photos/settings/s3_listing.dart';
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
  prefix: 'bring-your-own-photos/',
);

void main() {
  testWidgets('lists folders and objects, with sizes formatted', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BucketBrowserScreen(
          target: _target,
          listBucketFn:
              ({required target, prefix = '', continuationToken}) async =>
                  S3ListingResult(
                    S3ListingOutcome.ok,
                    page: S3ListingPage(
                      folders: const ['bring-your-own-photos/originals/'],
                      objects: [
                        S3Object(
                          key: 'bring-your-own-photos/notes.txt',
                          size: 2048,
                          lastModified: DateTime(2024, 1, 1),
                        ),
                      ],
                    ),
                  ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('originals/'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
  });

  testWidgets('tapping a folder drills into it with the deeper prefix', (
    tester,
  ) async {
    var requestedPrefix = '';
    await tester.pumpWidget(
      _wrap(
        BucketBrowserScreen(
          target: _target,
          listBucketFn:
              ({required target, prefix = '', continuationToken}) async {
                requestedPrefix = prefix;
                if (prefix == 'bring-your-own-photos/') {
                  return const S3ListingResult(
                    S3ListingOutcome.ok,
                    page: S3ListingPage(
                      folders: ['bring-your-own-photos/originals/'],
                      objects: [],
                    ),
                  );
                }
                return const S3ListingResult(
                  S3ListingOutcome.ok,
                  page: S3ListingPage(folders: [], objects: []),
                );
              },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('originals/'));
    await tester.pumpAndSettle();

    expect(requestedPrefix, 'bring-your-own-photos/originals/');
    expect(
      find.text('originals'),
      findsOneWidget,
    ); // AppBar title, trailing slash trimmed
    expect(find.text('This folder is empty.'), findsOneWidget);
  });

  testWidgets('shows an inline error when the listing is forbidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BucketBrowserScreen(
          target: _target,
          listBucketFn:
              ({required target, prefix = '', continuationToken}) async =>
                  const S3ListingResult(
                    S3ListingOutcome.forbidden,
                    detail: 'AccessDenied',
                  ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Access denied'), findsOneWidget);
    expect(find.textContaining('AccessDenied'), findsOneWidget);
  });

  testWidgets(
    'shows a Load More button when the page is truncated, and fetches the next page',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _wrap(
          BucketBrowserScreen(
            target: _target,
            listBucketFn:
                ({required target, prefix = '', continuationToken}) async {
                  calls++;
                  if (continuationToken == null) {
                    return S3ListingResult(
                      S3ListingOutcome.ok,
                      page: S3ListingPage(
                        folders: const [],
                        objects: [
                          S3Object(
                            key: 'bring-your-own-photos/a.jpg',
                            size: 1,
                            lastModified: DateTime(2024, 1, 1),
                          ),
                        ],
                        nextToken: 'page2',
                      ),
                    );
                  }
                  return S3ListingResult(
                    S3ListingOutcome.ok,
                    page: S3ListingPage(
                      folders: const [],
                      objects: [
                        S3Object(
                          key: 'bring-your-own-photos/b.jpg',
                          size: 1,
                          lastModified: DateTime(2024, 1, 1),
                        ),
                      ],
                    ),
                  );
                },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('a.jpg'), findsOneWidget);
      expect(find.text('b.jpg'), findsNothing);
      expect(find.text('Load More'), findsOneWidget);

      await tester.tap(find.text('Load More'));
      await tester.pumpAndSettle();

      expect(calls, 2);
      expect(find.text('a.jpg'), findsOneWidget);
      expect(find.text('b.jpg'), findsOneWidget);
      expect(find.text('Load More'), findsNothing);
    },
  );

  testWidgets('tapping an object opens its preview screen', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BucketBrowserScreen(
          target: _target,
          listBucketFn:
              ({required target, prefix = '', continuationToken}) async =>
                  S3ListingResult(
                    S3ListingOutcome.ok,
                    page: S3ListingPage(
                      folders: const [],
                      objects: [
                        S3Object(
                          key: 'bring-your-own-photos/a.jpg',
                          size: 1,
                          lastModified: DateTime(2024, 1, 1),
                        ),
                      ],
                    ),
                  ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('a.jpg'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final preview = tester.widget<BucketObjectPreviewScreen>(
      find.byType(BucketObjectPreviewScreen),
    );
    expect(preview.objectKey, 'bring-your-own-photos/a.jpg');
  });
}
