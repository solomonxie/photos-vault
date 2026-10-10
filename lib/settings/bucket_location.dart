import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../upload/object_location.dart';
import '../upload/signing.dart' as signing;
import '../vault/bucket.dart';
import 'bucket_browser_screen.dart';
import 's3_backup_target.dart';

/// Where a photo actually sits, reached from the photo: the app's own
/// Bucket Browser opened at the object's folder, or the bucket's own URL
/// handed to the phone's browser.
///
/// Offered from the share sheet on every backed-up photo, hidden or not —
/// "share" is already the question of where else this photo can go, and
/// the bucket is the one place it is known to already be.
///
/// Either way the object has to be found first: a record remembers one
/// key, and only a bucket can say whether that key is in *this* target.

typedef TargetLookup = Future<S3BackupTarget?> Function(String objectKey);

/// The folder [objectKey] lives in, as a listing prefix.
String folderPrefixOf(String objectKey) => objectKey.contains('/')
    ? objectKey.substring(0, objectKey.lastIndexOf('/') + 1)
    : '';

/// The Bucket Browser, rooted at the object's own folder rather than at
/// the connection's prefix — the point of coming from a photo is to land
/// beside it, not at the top of the bucket.
Future<void> showObjectInBucketBrowser(
  BuildContext context, {
  required String objectKey,
  TargetLookup locate = targetHolding,
}) async {
  final target = await _locate(context, objectKey, locate);
  if (target == null || !context.mounted) return;
  await Navigator.of(context).push(
    CupertinoPageRoute(
      builder: (_) => BucketBrowserScreen(
        target: target,
        prefix: folderPrefixOf(VaultBucket.resolveKey(target, objectKey)),
        highlightKey: VaultBucket.resolveKey(target, objectKey),
      ),
    ),
  );
}

/// The object in the phone's own browser, through a presigned URL — the
/// system browser deliberately, not an in-app one: this is the link you
/// went looking for so you could send it, save it, or open it on the
/// laptop, and an in-app web view is a dead end for all three.
///
/// An hour rather than the upload window's fifteen minutes: a link somebody
/// is reading gets reloaded, and re-signing it means coming back in here.
///
/// For a hidden photo this opens the *carrier* — the ordinary-looking photo
/// the bucket holds. Browser history gets a URL to a picture of somebody
/// else's day, which is exactly what anyone reading the bucket sees.
Future<void> openObjectInSystemBrowser(
  BuildContext context, {
  required String objectKey,
  TargetLookup locate = targetHolding,
  Future<Uri> Function({
        required S3BackupTarget target,
        required String key,
        Duration expiresIn,
      })
      presign =
      signing.presignGetUrl,
  Future<bool> Function(Uri url) open = _openExternally,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final target = await _locate(context, objectKey, locate);
  if (target == null) return;
  try {
    final url = await presign(
      target: target,
      key: VaultBucket.resolveKey(target, objectKey),
      expiresIn: const Duration(hours: 1),
    );
    if (!await open(url)) throw const FormatException('no handler');
  } catch (e) {
    if (context.mounted) {
      await _note(
        context,
        '${l10n.bucketObjectUnreachable} (${e.runtimeType})',
      );
    }
  }
}

Future<bool> _openExternally(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// Which target holds it, behind a spinner — one round trip per configured
/// bucket, and a tap that does nothing for two seconds reads as broken.
Future<S3BackupTarget?> _locate(
  BuildContext context,
  String objectKey,
  TargetLookup locate,
) async {
  final l10n = AppLocalizations.of(context)!;
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CupertinoActivityIndicator()),
    ),
  );
  final target = await locate(objectKey);
  if (navigator.canPop()) navigator.pop();
  if (target == null && context.mounted) {
    final why = lastLookupDetail;
    await _note(
      context,
      why == null
          ? l10n.bucketObjectUnreachable
          : '${l10n.bucketObjectUnreachable} ($why)',
    );
  }
  return target;
}

Future<void> _note(BuildContext context, String message) =>
    showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(AppLocalizations.of(context)!.actionOk),
          ),
        ],
      ),
    );
