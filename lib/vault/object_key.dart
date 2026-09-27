import '../storage/asset_record.dart';

/// The name a hidden photo's carrier goes by, everywhere: in the album
/// index, in the local store, and — joined to a bucket's own prefix by
/// `VaultBucket.resolveKey` — in every bucket.
///
/// Deliberately **relative**. A key carrying a bucket's prefix ties the
/// index to one bucket, and ties a hidden photo's existence to having a
/// bucket at all. This one is worked out from the record alone, before
/// anything is configured, which is what lets the copy on this phone be the
/// primary one and the bucket an optional second.
String vaultObjectKey(String derivativeDir, String fileName) =>
    '$derivativeDir/$fileName';

/// The same name, from the record alone — for the callers that have to know
/// a carrier's key without having built one.
///
/// Two invariants hold it to what `BackupCoordinator` actually uploads, and
/// both are asserted by `test/vault/object_key_test.dart` rather than left
/// to a comment: the id is sanitised the same way, and a carrier is written
/// as `carrier.jpg` or `carrier.mov` (`CarrierBuilder`), so the extension is
/// decided by whether the record counts as a video.
String vaultCarrierKey(AssetRecord record) => vaultObjectKey(
  'originals',
  '${vaultSafeName(record.localId)}${record.countsAsVideo ? '.mov' : '.jpg'}',
);

/// A Live Photo's motion half, which is a second carrier under a second
/// key: the still is `<id>.jpg` and the `.mov` beside it is `<id>.mov`.
/// They are one photo, so they share a name and differ by extension — and
/// both have to be held before the plaintext originals can go, because a
/// Live Photo kept as a still alone is a silent still.
String vaultLiveCarrierKey(AssetRecord record) =>
    vaultObjectKey('originals', '${vaultSafeName(record.localId)}.mov');

/// Anything a bucket, a filesystem and a URL all accept. Shared with
/// `BackupCoordinator.safeFileName` so the two cannot drift.
String vaultSafeName(String localId) =>
    localId.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
