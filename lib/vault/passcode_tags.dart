import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../photos/person_store.dart';
import '../settings/secure_store.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import 'carrier.dart' show randomBytes;
import 'cipher.dart';
import 'keys.dart';

/// Turns a typed code into the tag its album, folder or sealed set is kept
/// under: HMAC under a random key in the keychain ([passcodeTagWith]). The
/// tag is the same on every unlock, and without the key no copy of the
/// database says which code it stands for.
///
/// Older builds stored `sha256(code)` ([hashPasscode]). Both are accepted:
///
/// - **Dual check on unlock** ([tagFor]): whatever is still under the old
///   form, or under a key this phone used before, is moved to the current
///   tag in the same unlock. The old form keeps being accepted for as long
///   as anything carries it.
/// - **At launch** ([upgradeLegacy]): old tags are reversed off the UI
///   isolate (they are 10,000 tries each) and moved, so a backup taken
///   before the next unlock already holds none.
///
/// A missing key never locks anyone out. The key is escrowed in the
/// database sealed under each passphrase's master key, and travels in the
/// app-data export, so a new phone that has the passphrase typed gets the
/// key back. No passphrase on hand: a new key, and the old tags are tried
/// again on every unlock once one is.
///
/// Codes, tags and keys are never logged.
class PasscodeTags {
  PasscodeTags({
    required this.records,
    PersonStore? people,
    VaultKeys? vaultKeys,
    SecureStore? store,
  }) : _givenPeople = people,
       _vaultKeys = vaultKeys ?? VaultKeys(),
       _store = store ?? vaultKeys?.secureStore ?? const FlutterSecureStore();

  final AssetRecordStore records;
  final PersonStore? _givenPeople;
  late final PersonStore _people = _givenPeople ?? PersonStore();
  final VaultKeys _vaultKeys;
  final SecureStore _store;

  static const keyName = 'passcode_tag_key_v1';
  static const escrowState = 'passcode_tag_escrow_v1';
  static const _unresolvedState = 'passcode_tag_unresolved_v1';

  /// One load at a time, process-wide: two first unlocks at once must not
  /// each mint a key.
  static Future<Uint8List>? _loading;

  /// [code]'s tag, with anything kept under its older forms moved to it.
  /// The old form itself when the keychain can't be read: still accepted,
  /// and moved on the next unlock that can read it.
  Future<String> tagFor(String code) async {
    final Uint8List key;
    try {
      key = await _key();
    } catch (_) {
      return hashPasscode(code);
    }
    final tag = passcodeTagWith(key, code);
    final older = {
      hashPasscode(code),
      for (final other in await _escrowedKeys())
        if (!bytesMatch(other, key)) passcodeTagWith(other, code),
    };
    for (final from in older) {
      await _retag(from, tag);
    }
    await _escrow(key);
    return tag;
  }

  /// The key tags are made under now, or null when the keychain can't be
  /// read — for checks that only look, such as [personHasHiddenFolder].
  Future<Uint8List?> currentKey() async {
    try {
      return await _key();
    } catch (_) {
      return null;
    }
  }

  /// Moves every old-form tag whose code can be found to its current tag.
  /// Returns how many tags moved.
  Future<int> upgradeLegacy() async {
    final legacy = {
      ...await records.passcodeHashes(),
      ...await _people.namespaces(),
      ...await _vaultKeys.ringTags(),
    }.where(isLegacyTag).toSet();
    if (legacy.isEmpty) return 0;
    final Uint8List key;
    try {
      key = await _key();
    } catch (_) {
      return 0;
    }
    final ids = [for (final p in await _people.listAll()) p.id]..sort();
    final mark = sha256
        .convert(utf8.encode([...legacy.toList()..sort(), '|', ...ids].join()))
        .toString();
    if (await records.getAppState(_unresolvedState) == mark) return 0;
    final moves = await Isolate.run(() => _upgrades(legacy, ids, key));
    for (final MapEntry(key: from, value: to) in moves.entries) {
      await _retag(from, to);
    }
    if (moves.length < legacy.length) {
      // A deleted person's folder, or a code of another shape: tried again
      // when something changes, and on unlock either way.
      await records.setAppState(_unresolvedState, mark);
    }
    await _escrow(key);
    return moves.length;
  }

  static Map<String, String> _upgrades(
    Set<String> legacy,
    List<String> personIds,
    Uint8List key,
  ) => {
    for (final MapEntry(key: tag, value: code) in reverseLegacyTags(
      legacy,
      personIds,
    ).entries)
      tag: passcodeTagWith(key, code),
  };

  Future<void> _retag(String from, String to) async {
    if (from == to) return;
    // Each on its own: one that fails keeps the old form, which is still
    // accepted, so it moves on a later unlock.
    try {
      await records.retag(from, to);
    } catch (_) {}
    try {
      await _people.retag(from, to);
    } catch (_) {}
    try {
      await _vaultKeys.renameAlbum(from, to);
    } catch (_) {}
  }

  Future<Uint8List> _key() => _loading ??= _load().whenComplete(() {
    _loading = null;
  });

  Future<Uint8List> _load() async {
    final stored = await _store.read(keyName);
    if (stored != null) return Uint8List.fromList(base64Decode(stored));
    // Gone from the keychain (a restore without it): the escrowed one, so
    // the tags already in the database still match.
    final escrowed = await _escrowedKeys();
    final key = escrowed.isNotEmpty ? escrowed.last : randomBytes(32);
    await _store.write(keyName, base64Encode(key));
    return key;
  }

  Future<List<Map<String, dynamic>>> _escrows() async {
    try {
      final raw = await records.getAppState(escrowState);
      if (raw == null) return [];
      return [
        for (final e in jsonDecode(raw) as List)
          (e as Map).cast<String, dynamic>(),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Every key an escrow this phone's passphrases open holds, oldest first.
  Future<List<Uint8List>> _escrowedKeys() async {
    final out = <Uint8List>[];
    for (final e in await _escrows()) {
      final sealKey = await _sealKey(e['e'] as String?);
      if (sealKey == null) continue;
      final opened = openEscrow(sealKey, e);
      if (opened != null && !out.any((k) => bytesMatch(k, opened))) {
        out.add(opened);
      }
    }
    return out;
  }

  Future<Uint8List?> _sealKey(String? entryId) async {
    if (entryId == null) return null;
    try {
      return await _vaultKeys.escrowKey(entryId);
    } catch (_) {
      return null;
    }
  }

  /// Seals [key] under every passphrase on hand that doesn't hold it yet.
  Future<void> _escrow(Uint8List key) async {
    try {
      final escrows = await _escrows();
      var changed = false;
      for (final entryId in await _vaultKeys.entryIdsOnHand()) {
        final sealKey = await _vaultKeys.escrowKey(entryId);
        if (sealKey == null) continue;
        final held = escrows.any((e) {
          if (e['e'] != entryId) return false;
          final opened = openEscrow(sealKey, e);
          return opened != null && bytesMatch(opened, key);
        });
        if (held) continue;
        escrows.add({'e': entryId, ...sealEscrow(sealKey, key)});
        changed = true;
      }
      if (changed) {
        await records.setAppState(escrowState, jsonEncode(escrows));
      }
    } catch (_) {
      // Escrowed on a later unlock.
    }
  }

  /// The escrow rows, sealed as stored — for the app-data export.
  Future<List<Map<String, dynamic>>> exportEscrows() => _escrows();

  /// Escrow rows from an export, added beside this phone's.
  Future<void> importEscrows(List<Map<String, dynamic>> incoming) async {
    if (incoming.isEmpty) return;
    final escrows = await _escrows();
    final seen = {for (final e in escrows) e['n']};
    for (final e in incoming) {
      if (e['e'] is! String || e['n'] is! String || seen.contains(e['n'])) {
        continue;
      }
      escrows.add({'e': e['e'], 'n': e['n'], 'c': e['c'], 'm': e['m']});
      seen.add(e['n']);
    }
    await records.setAppState(escrowState, jsonEncode(escrows));
  }
}

/// [key] under [sealKey]: a pad from HKDF over a fresh nonce, and a MAC.
Map<String, String> sealEscrow(Uint8List sealKey, Uint8List key) {
  final nonce = randomBytes(16);
  final body = _xor(key, _pad(sealKey, nonce, key.length));
  return {
    'n': base64Encode(nonce),
    'c': base64Encode(body),
    'm': base64Encode(_mac(sealKey, nonce, body)),
  };
}

Uint8List? openEscrow(Uint8List sealKey, Map<String, dynamic> escrow) {
  try {
    final nonce = base64Decode(escrow['n'] as String);
    final body = base64Decode(escrow['c'] as String);
    final mac = base64Decode(escrow['m'] as String);
    if (!bytesMatch(_mac(sealKey, nonce, body), mac)) return null;
    return _xor(body, _pad(sealKey, nonce, body.length));
  } catch (_) {
    return null;
  }
}

Uint8List _pad(Uint8List sealKey, List<int> nonce, int length) =>
    hkdf(key: sealKey, info: [...utf8.encode('pad'), ...nonce], length: length);

Uint8List _mac(Uint8List sealKey, List<int> nonce, List<int> body) =>
    Uint8List.sublistView(
      vaultHmacParts(sealKey, [utf8.encode('mac'), nonce, body]),
      0,
      16,
    );

Uint8List _xor(List<int> a, List<int> b) =>
    Uint8List.fromList([for (var i = 0; i < a.length; i++) a[i] ^ b[i]]);
