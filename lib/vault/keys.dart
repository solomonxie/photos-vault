import 'dart:convert';
import 'dart:typed_data';

import '../settings/secure_store.dart';
import '../storage/passcode_hash.dart';
import 'carrier.dart';
import 'cipher.dart';

/// Key material for the private albums.
///
/// ```text
/// passphrase ─PBKDF2, 600k, per-entry salt─▶ masterKey   keychain, once
///      │ HKDF, with the 4 digits typed at the gate       free, per unlock
///      ▼
///   albumKey ─▶ carrier keys, index section tag          RAM only
/// ```
///
/// Never the database: sqlite rides to the bucket in the daily snapshot,
/// which is where the carriers are, so a key kept there would be a key
/// taped to its own lock. The salt, verifier and hint are not secret and
/// live in the index object so a restored phone can find them; while there
/// is no bucket they sit beside the key in the keychain.
///
/// More than one entry can exist at once, and they merge rather than
/// replace: a phone that set a passphrase before restoring an older one
/// must be able to open both generations, and dropping an entry would
/// strand every carrier it opens.
const passphraseIterations = 600000;
const minimumPassphraseLength = 8;

class PassphraseEntry {
  const PassphraseEntry({
    required this.id,
    required this.salt,
    required this.verifier,
    required this.hint,
  });

  factory PassphraseEntry.fromJson(Map<String, dynamic> json) =>
      PassphraseEntry(
        id: json['id'] as String,
        salt: base64Decode(json['salt'] as String),
        verifier: base64Decode(json['verifier'] as String),
        hint: json['hint'] as String? ?? '',
      );

  /// Identifies the keychain item holding this entry's master key. Derived
  /// from the salt, so it names no album and counts nothing.
  final String id;
  final Uint8List salt;
  final Uint8List verifier;
  final String hint;

  Map<String, dynamic> toJson() => {
    'id': id,
    'salt': base64Encode(salt),
    'verifier': base64Encode(verifier),
    'hint': hint,
  };
}

class AlbumKeys {
  const AlbumKeys({required this.albumKey, required this.entry});

  final Uint8List albumKey;
  final PassphraseEntry entry;

  CarrierKeys get carrier => CarrierKeys.forAlbum(albumKey);

  /// Which slice of the index object is this album's. Tagged rather than
  /// named, so the file says nothing about how many albums are real.
  Uint8List get sectionTag =>
      Uint8List.sublistView(vaultHmac(albumKey, 'section'.codeUnits), 0, 16);
}

class VaultKeys {
  VaultKeys({SecureStore? store, VaultCipher? cipher})
    : _store = store ?? const FlutterSecureStore(),
      _cipher = cipher ?? PlatformCipher();

  final SecureStore _store;
  final VaultCipher _cipher;

  static const _entriesKey = 'vault_passphrase_entries';
  static const _masterPrefix = 'vault_master_';

  /// Held only while the app is alive. Closing the album, or the app dying,
  /// takes them with it.
  final Map<String, Uint8List> _unlocked = {};

  Future<List<PassphraseEntry>> entries() async {
    final raw = await _store.read(_entriesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          PassphraseEntry.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Adds [passphrase] as an entry and remembers its master key. Existing
  /// entries are kept: typing an old passphrase here is how a restored
  /// phone gets its old carriers back.
  Future<PassphraseEntry> add(String passphrase, {String hint = ''}) async {
    final salt = randomBytes(16);
    final master = _cipher.deriveKey(
      passphrase: passphrase,
      salt: salt,
      iterations: passphraseIterations,
    );
    final entry = PassphraseEntry(
      id: base64Url.encode(vaultHmac(salt, 'id'.codeUnits).sublist(0, 9)),
      salt: salt,
      verifier: vaultHmac(master, 'verify'.codeUnits),
      hint: hint,
    );
    await _remember(entry, master);
    return entry;
  }

  /// Re-derives a known entry from [passphrase] — the path a new phone
  /// takes, where the entry came out of the index object but its master key
  /// never left the old phone's keychain. False when the passphrase is
  /// wrong, which only this screen may say out loud; the 4-digit gate never
  /// does.
  Future<bool> unlockEntry(PassphraseEntry entry, String passphrase) async {
    final master = _cipher.deriveKey(
      passphrase: passphrase,
      salt: entry.salt,
      iterations: passphraseIterations,
    );
    if (!bytesMatch(vaultHmac(master, 'verify'.codeUnits), entry.verifier)) {
      return false;
    }
    await _remember(entry, master);
    return true;
  }

  Future<void> _remember(PassphraseEntry entry, Uint8List master) async {
    final known = await entries();
    if (!known.any((e) => e.id == entry.id)) {
      await _store.write(
        _entriesKey,
        jsonEncode([...known.map((e) => e.toJson()), entry.toJson()]),
      );
    }
    await _store.write('$_masterPrefix${entry.id}', base64Encode(master));
    _unlocked[entry.id] = master;
  }

  Future<Uint8List?> _masterKey(PassphraseEntry entry) async {
    final cached = _unlocked[entry.id];
    if (cached != null) return cached;
    final stored = await _store.read('$_masterPrefix${entry.id}');
    if (stored == null) return null;
    final key = Uint8List.fromList(base64Decode(stored));
    _unlocked[entry.id] = key;
    return key;
  }

  /// Every album key [passcode] produces, one per passphrase this phone can
  /// still derive. Wrong digits are not an error and cannot be: they simply
  /// produce keys that open nothing.
  Future<List<AlbumKeys>> albumKeys(String passcode) async {
    final out = <AlbumKeys>[];
    for (final entry in await entries()) {
      final master = await _masterKey(entry);
      if (master == null) continue;
      out.add(
        AlbumKeys(
          albumKey: Uint8List.sublistView(
            hkdf(key: master, info: utf8.encode('album:$passcode')),
            0,
            32,
          ),
          entry: entry,
        ),
      );
    }
    return out;
  }

  /// The active entry — what new carriers are encrypted with. The newest,
  /// which is the one the user most recently typed.
  Future<AlbumKeys?> activeAlbumKeys(String passcode) async {
    final all = await albumKeys(passcode);
    return all.isEmpty ? null : all.last;
  }

  /// Album keys for codes typed this session, kept under the same hash the
  /// records carry so the upload path can find them without ever holding
  /// the digits. Dropped when the app dies; nothing writes them down.
  final Map<String, AlbumKeys> _ring = {};

  /// Called when the gate opens an album. Returns the keys for [passcode],
  /// or null when this phone has no passphrase yet — the upload path then
  /// holds the job rather than failing it.
  Future<AlbumKeys?> unlockAlbum(String passcode) async {
    final keys = await activeAlbumKeys(passcode);
    if (keys == null) return null;
    _ring[hashPasscode(passcode)] = keys;
    return keys;
  }

  /// Every key typed this session for [passcodeHash] — the active one, plus
  /// older passphrases added inside the album.
  AlbumKeys? ringKeysFor(String passcodeHash) => _ring[passcodeHash];

  void lockAll() => _ring.clear();

  /// Forgets this phone's master keys. The carriers stay where they are and
  /// the passphrase still opens them; this phone just stops being able to
  /// until it is typed again.
  ///
  /// The **entries** deliberately survive — their salt, verifier and hint
  /// are what let a retyped passphrase re-derive the master key. Deleting
  /// them instead is what sends [openPrivateAlbum]'s gate down its "set up
  /// a new passphrase" branch, which mints a fresh salt, derives a key that
  /// matches no carrier, and opens an album that looks empty. Nothing is
  /// lost on the way back from that, but nobody would find the way back.
  ///
  /// Also why this is safe to leave behind on Remove All App Data: the same
  /// salts, verifiers and hints ride in the plaintext header of the
  /// bucket's own `index.bin`, so keeping them on the phone reveals nothing
  /// the destination doesn't already hold in the open.
  Future<void> forgetOnThisDevice() async {
    for (final entry in await entries()) {
      await _store.delete('$_masterPrefix${entry.id}');
    }
    _unlocked.clear();
    _ring.clear();
  }
}
