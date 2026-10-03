import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../storage/asset_record.dart';
import 'carrier.dart';
import 'cipher.dart';

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

/// `<YYYYMMDDHHMMSS>_<32 hex>`: the base name of every object this app
/// writes, ordinary or hidden, so a listing tells them apart by nothing.
///
/// Ordinary: the photo's date and a hash of its id. Hidden: a keyed date
/// and `nonce | locator`, where the locator is the very value in the
/// carrier's own header - so an unlocked album recognises its files by name,
/// and a stranger sees 32 hex characters like any other.
final _protocolName = RegExp(r'^(\d{14})_([0-9a-f]{32})(\.[A-Za-z0-9]+)?$');

class ProtocolName {
  const ProtocolName(this.stamp, this.nonce, this.tag);

  final String stamp;
  final Uint8List nonce;
  final Uint8List tag;
}

/// Null for any name that does not fit - which includes every old
/// `photo_<UUID>_L0_001` name.
ProtocolName? parseProtocolName(String fileName) {
  final m = _protocolName.firstMatch(fileName.split('/').last);
  if (m == null) return null;
  final raw = _fromHex(m[2]!);
  return ProtocolName(
    m[1]!,
    Uint8List.sublistView(raw, 0, nonceBytes),
    Uint8List.sublistView(raw, nonceBytes),
  );
}

bool fitsProtocol(String fileName) => parseProtocolName(fileName) != null;

/// Whether [macKey] is the key of the album that wrote [fileName]. Local,
/// instant, and false for every ordinary name and every other album.
bool nameBelongsTo(String fileName, Uint8List macKey) {
  final parsed = parseProtocolName(fileName);
  if (parsed == null) return false;
  return bytesMatch(parsed.tag, _locatorOf(macKey, parsed.nonce));
}

String objectStamp(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${when.year.toString().padLeft(4, '0')}${two(when.month)}'
      '${two(when.day)}${two(when.hour)}${two(when.minute)}${two(when.second)}';
}

DateTime? parseObjectStamp(String stamp) {
  if (stamp.length != 14) return null;
  final parts = [
    int.tryParse(stamp.substring(0, 4)),
    for (var i = 4; i < 14; i += 2) int.tryParse(stamp.substring(i, i + 2)),
  ];
  if (parts.contains(null)) return null;
  final v = parts.cast<int>();
  if (v[1] < 1 || v[1] > 12 || v[2] < 1 || v[2] > 31 || v[3] > 23) return null;
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}

/// An ordinary photo's base name. Stable for the record (a hash, not a
/// dice roll), so a retried upload lands on the same key.
String ordinaryBaseName(AssetRecord record) {
  final hash = sha256.convert(utf8.encode(record.localId)).bytes;
  return '${objectStamp(record.createdAt)}_${_hex(hash.sublist(0, 16))}';
}

/// A hidden photo's base name, worked out from the record and the album's
/// keys alone - which is why nothing has to remember it between building a
/// carrier and filing it.
String hiddenBaseName(CarrierKeys keys, AssetRecord record) =>
    hiddenBaseNameFor(keys, record.localId);

/// The same, from any stable string: a record's id, or - when an old
/// carrier is given a protocol name - its old object key.
String hiddenBaseNameFor(CarrierKeys keys, String seed) {
  final nonce = hiddenNonceFor(keys, seed);
  return '${objectStamp(_hiddenDate(keys, seed))}_'
      '${_hex(nonce)}${_hex(_locatorOf(keys.macKey, nonce))}';
}

/// Goes in the carrier header as well, so the name and the file agree.
Uint8List hiddenNonce(CarrierKeys keys, AssetRecord record) =>
    hiddenNonceFor(keys, record.localId);

Uint8List hiddenNonceFor(CarrierKeys keys, String seed) =>
    Uint8List.sublistView(
      vaultHmac(keys.nameKey, utf8.encode('nonce|$seed')),
      0,
      nonceBytes,
    );

/// Keyed and arbitrary: the real taken date must not show, and a decoy's
/// date is not known again when the name is worked out later.
DateTime _hiddenDate(CarrierKeys keys, String seed) {
  final mac = vaultHmac(keys.nameKey, utf8.encode('date|$seed'));
  final span =
      DateTime.utc(2026).millisecondsSinceEpoch ~/ 1000 -
      DateTime.utc(2012).millisecondsSinceEpoch ~/ 1000;
  final offset = ByteData.sublistView(mac).getUint32(0) % span;
  return DateTime.fromMillisecondsSinceEpoch(
    (DateTime.utc(2012).millisecondsSinceEpoch ~/ 1000 + offset) * 1000,
    isUtc: true,
  ).toLocal();
}

/// A carrier found in a bucket under some other name, given the name its
/// own header asks for - needs no key, because the nonce and locator are
/// already in the file.
String hiddenBaseNameFromHeader(DateTime when, CarrierHeader header) =>
    '${objectStamp(when)}_${_hex(header.nonce!)}${_hex(header.storedLocator!)}';

Uint8List _locatorOf(Uint8List macKey, Uint8List nonce) =>
    Uint8List.sublistView(vaultHmac(macKey, nonce), 0, 8);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

/// The key the carrier of [record] goes by - from the record and the
/// album's keys, because with no bucket there is no destination key to read.
/// Two invariants hold it to what `BackupCoordinator` uploads: a carrier is
/// written as `carrier.jpg` or `carrier.mov` (`CarrierBuilder`), so the
/// extension is decided by whether the record counts as a video.
String vaultCarrierKey(AssetRecord record, CarrierKeys keys) => vaultObjectKey(
  'originals',
  '${hiddenBaseName(keys, record)}${record.countsAsVideo ? '.mov' : '.jpg'}',
);

/// A Live Photo's motion half, which is a second carrier under a second
/// key: the still is `<base>.jpg` and the `.mov` beside it is `<base>.mov`.
/// They are one photo, so they share a name and differ by extension - and
/// both have to be held before the plaintext originals can go, because a
/// Live Photo kept as a still alone is a silent still.
String vaultLiveCarrierKey(AssetRecord record, CarrierKeys keys) =>
    vaultObjectKey('originals', '${hiddenBaseName(keys, record)}.mov');

/// Anything a bucket, a filesystem and a URL all accept. Shared with
/// `BackupCoordinator.safeFileName` so the two cannot drift.
String vaultSafeName(String localId) =>
    localId.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
