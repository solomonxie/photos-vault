import 'dart:convert';

import 'asset_record_store.dart';

/// Which private albums are kept off the network.
///
/// Per album rather than one switch for all hiding, because an "album"
/// here is a passcode hash and nothing else (see
/// `AssetRecord.passcodeHash`) — one group can stay on this device while
/// another is backed up, without either deciding for the other.
///
/// **On unless turned off.** Hiding a photo takes it out of Photos, so
/// this app holds the only copy on the device; leaving the default at off
/// would quietly make the hidden album the least safe place in the
/// library. Turning it off is a deliberate choice, made on the screen that
/// spells out what it costs.
///
/// Stored as one `app_state` row — a JSON list of opted-out hashes —
/// rather than a row per album, so reading "who is opted out" is a single
/// lookup on the backup path. That row is device-local and isn't in the
/// app-data snapshot, so a restored install starts backing an album up
/// again until someone turns it off a second time. Failing that way round
/// is the deliberate one: the other direction silently stops backing up
/// photos the phone holds the only copy of.
class PrivateAlbumSync {
  const PrivateAlbumSync(this.store);

  final AssetRecordStore store;

  static const _key = 'private_album_sync_off';

  Future<Set<String>> disabledHashes() async {
    final raw = await store.getAppState(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as List).cast<String>().toSet();
    } catch (_) {
      // Unreadable row — treat it as "nobody opted out". The failure that
      // matters here is a photo silently not being backed up, so a corrupt
      // preference falls back to backing up, not to skipping.
      return {};
    }
  }

  Future<bool> isEnabled(String passcodeHash) async =>
      !(await disabledHashes()).contains(passcodeHash);

  Future<void> setEnabled(String passcodeHash, bool enabled) async {
    final disabled = await disabledHashes();
    final changed = enabled
        ? disabled.remove(passcodeHash)
        : disabled.add(passcodeHash);
    if (!changed) return;
    await store.setAppState(_key, jsonEncode(disabled.toList()));
  }
}
