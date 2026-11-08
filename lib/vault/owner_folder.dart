import '../photos/person_store.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import 'album_index.dart';
import 'filed_photos.dart';
import 'hidden_leftovers.dart';
import 'hidden_notes.dart';
import 'hidden_transition.dart';
import 'keys.dart';
import 'passcode_tags.dart';

/// Every hidden folder is a person's. The main page's Hidden opens the
/// owner's: `personAlbumCode(owner, digits)`. Whose a folder is lives only
/// in its code, so a database copy still can't tell whose folders exist.
///
/// Older builds kept the main page's folder under the bare digits. The
/// album key comes from the code, so it can't simply be re-tagged: its
/// carriers would stop opening. On each main-page unlock [adoptPlain]
/// moves what the bare digits hold into the owner's folder instead:
///
/// - photos go through [HiddenTransition.moveRecord], additively: their
///   uploads reset so the backup re-encrypts them under the owner's key,
///   and nothing under the old key is deleted from any bucket;
/// - album notes and sealed profile sets are sealed again under the
///   owner's key (local rows only);
/// - photos only the bucket has go through [carryBucketOnly], in the
///   background once the owner's folder is open: downloaded, decrypted
///   and given a row there, the backup sending them under the owner's key
///   as new objects; the old carriers stay and are only retired;
/// - whatever can't move (adopted by an older build, mid transition, a
///   download that failed) stays, and the owner's folder offers the bare
///   digits as a row of older photos while they still hold something of
///   their own.
///
/// Folders under bare digits that are never typed on the main page again
/// stay where they are.
class OwnerFolder {
  OwnerFolder({
    required this.store,
    required this.people,
    required this.vaultKeys,
    HiddenTransition? transition,
    BackupTargetsStore? targetsStore,
    Future<bool> Function(AlbumKeys keys, String tag)? bucketHolds,
  }) : _targets = targetsStore ?? BackupTargetsStore(),
       _transitionGiven = transition,
       _bucketHoldsGiven = bucketHolds;

  final AssetRecordStore store;
  final PersonStore people;
  final VaultKeys vaultKeys;
  final BackupTargetsStore _targets;
  final HiddenTransition? _transitionGiven;
  final Future<bool> Function(AlbumKeys keys, String tag)? _bucketHoldsGiven;

  late final HiddenTransition _transition =
      _transitionGiven ??
      HiddenTransition(store: store, loadTargets: _targets.loadAll);

  /// Moves what [digits] alone still hold into [ownerId]'s folder under
  /// the same digits. Returns [digits] when anything stayed behind.
  /// [lookInBucket] false skips asking whether the old key still has
  /// carriers of its own, for a caller that counts them itself or opens
  /// no folder.
  Future<List<String>> adoptPlain(
    String ownerId,
    String digits, {
    bool lookInBucket = true,
  }) async {
    final tags = PasscodeTags(
      records: store,
      people: people,
      vaultKeys: vaultKeys,
    );
    // Legacy and older-key forms of the bare digits come along here.
    final fromTag = await tags.tagFor(digits);
    final toCode = personAlbumCode(ownerId, digits);
    final toTag = await tags.tagFor(toCode);
    if (fromTag == toTag) return const [];
    final to = await vaultKeys.unlockAlbum(toCode, toTag);
    final fromAll = await vaultKeys.albumKeys(digits);
    final from = fromAll.isEmpty ? null : fromAll.last;

    var stuck = false;
    var moved = 0;
    final rows = await store.forPasscodeHash(fromTag);
    if (rows.isNotEmpty) {
      // Keeps backing up what stays.
      if (from != null) await vaultKeys.unlockAlbum(digits, fromTag);
      for (final record in rows) {
        final ok =
            (from == null || to != null) &&
            !isAdopted(record) &&
            await _transition.moveRecord(
              record,
              from: from,
              to: toTag,
              retire: false,
            );
        if (ok) {
          moved++;
        } else {
          stuck = true;
        }
      }
    }
    if (moved > 0) await vaultKeys.keepAlbum(toTag);

    if (to != null) {
      final target = HiddenNotes(store: store, keys: to);
      for (final keys in fromAll) {
        try {
          for (final note in await HiddenNotes(
            store: store,
            keys: keys,
          ).list()) {
            // Same id: the row is replaced, never doubled or dropped.
            await target.save(note.text, existing: note);
          }
        } catch (_) {
          // Left sealed under the old key; moved on a later unlock.
        }
      }
      try {
        if (await people.reseal(fromTag, fromAll, toTag, to) > 0) {
          await vaultKeys.keepAlbum(toTag);
        }
      } catch (_) {}
    }

    if (stuck) return [digits];
    if (lookInBucket && from != null && await _bucketHolds(from, fromTag)) {
      return [digits];
    }
    return const [];
  }

  Future<bool> _bucketHolds(AlbumKeys keys, String tag) async {
    if (_bucketHoldsGiven case final given?) return given(keys, tag);
    try {
      return await HiddenLeftovers(store: store).count(tag, keys) > 0;
    } catch (_) {
      // Can't tell: kept reachable, so nothing is out of reach.
      return true;
    }
  }
}

/// Carries every photo only the bucket has under [from] (tagged
/// [fromTag]) into the folder tagged [toTag] ([FiledPhotos.carry]), one at
/// a time. Downloads ride the native background transfer; decryption and
/// hashing run off the UI isolate. [moved] counts photos carried and
/// carriers every bucket has lost (both stop counting in the source);
/// [stuck] what stays for a later try.
Future<({int moved, int stuck})> carryBucketOnly({
  required AssetRecordStore store,
  required AlbumKeys from,
  required String fromTag,
  required String toTag,
  FiledPhotos? filed,
  HiddenLeftovers? leftovers,
}) async {
  if (fromTag == toTag) return (moved: 0, stuck: 0);
  final carrier = filed ?? FiledPhotos(records: store);
  final entries = await (leftovers ?? HiddenLeftovers(store: store)).bucketOnly(
    fromTag,
    from,
  );
  var moved = 0;
  var stuck = 0;
  for (final entry in entries) {
    try {
      if (await carrier.carry(from, entry, toTag) == CarryOutcome.failed) {
        stuck++;
      } else {
        moved++;
      }
    } catch (_) {
      stuck++;
    }
  }
  return (moved: moved, stuck: stuck);
}

/// What [moveToPersonFolder] did.
class HiddenMoveResult {
  const HiddenMoveResult({
    this.moved = 0,
    this.sameFolder = false,
    this.noKey = false,
  });

  final int moved;

  /// The person's folder under these digits is the one they're in.
  final bool sameFolder;

  /// The source has carriers but the destination's key can't be derived.
  final bool noKey;
}

/// Moves [localIds] from the folder tagged [fromTag] into [personId]'s
/// folder under the same [digits], made by the move if it held nothing.
///
/// Additive, never a delete: each photo's uploads reset so the backup
/// re-encrypts it under the person's key, and its carriers under [from]
/// stay in every bucket ([HiddenTransition.moveRecord] with `retire:
/// false`). Album notes belong to the folder, not to a photo, and stay.
/// [entries], photos only the bucket has, are carried there
/// ([FiledPhotos.carry]): downloaded, decrypted, given a row, sent again
/// under the person's key by the backup; their old carriers stay and are
/// retired. A photo that can't move (adopted by an older build, a
/// transition under way, a download or write that fails) stays in
/// [fromTag].
Future<HiddenMoveResult> moveToPersonFolder({
  required AssetRecordStore store,
  required VaultKeys? vaultKeys,
  required HiddenTransition transition,
  required AlbumKeys? from,
  required String fromTag,
  required String personId,
  required String digits,
  required Iterable<String> localIds,
  Iterable<IndexEntry> entries = const [],
  PersonStore? people,
  FiledPhotos? filed,
}) async {
  final code = personAlbumCode(personId, digits);
  final tag = await PasscodeTags(
    records: store,
    people: people,
    vaultKeys: vaultKeys,
  ).tagFor(code);
  if (tag == fromTag) return const HiddenMoveResult(sameFolder: true);
  final to = vaultKeys == null ? null : await vaultKeys.unlockAlbum(code, tag);
  // Its carriers here can only be superseded once it has a key there.
  if (from != null && to == null) return const HiddenMoveResult(noKey: true);
  var moved = 0;
  for (final id in localIds) {
    final record = await store.getByLocalId(id);
    if (record == null || record.passcodeHash != fromTag) continue;
    if (isAdopted(record)) continue;
    try {
      if (await transition.moveRecord(
        record,
        from: from,
        to: tag,
        retire: false,
      )) {
        moved++;
      }
    } catch (_) {
      // Still here, or finished by the journal on the next launch.
    }
  }
  if (from != null && entries.isNotEmpty) {
    final carrier = filed ?? FiledPhotos(records: store);
    for (final entry in entries) {
      try {
        if (await carrier.carry(from, entry, tag) == CarryOutcome.moved) {
          moved++;
        }
      } catch (_) {
        // Still here, counted as before.
      }
    }
  }
  if (moved > 0) await vaultKeys?.keepAlbum(tag);
  return HiddenMoveResult(moved: moved);
}
