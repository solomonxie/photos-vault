import '../l10n/app_localizations.dart';
import '../photos/asset_removal.dart';
import '../photos/photo_library_service.dart';
import '../photos/person_store.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../vault/album_index.dart';
import '../vault/bucket.dart';
import '../vault/gallery.dart';
import '../vault/hidden_bucket_scan.dart';
import '../vault/hidden_removal.dart';
import '../vault/keys.dart';
import '../vault/object_key.dart';
import 'delete_confirmation.dart';
import 'private_album_gate.dart';

/// What deleting people takes with them, worked out before asking.
typedef PersonDeletionPlan = ({
  /// Tagged on them and on nobody else left in People.
  List<AssetRecord> photos,

  /// Each one's hidden folders, tag → code, whatever the digits.
  Map<String, Map<String, String>> folders,
  int hiddenCount,
});

/// Deleting a person deletes their photos too: the ones no one else in
/// People is in go to Recently Deleted, and every hidden folder of theirs
/// goes for good. A photo that also shows someone still here stays.
class PersonDeletion {
  PersonDeletion({
    required this.personStore,
    required this.assetRecordStore,
    VaultKeys? vaultKeys,
    BackupTargetsStore? targetsStore,
    PhotoLibraryService? library,
    AssetRemoval? removal,
    Future<bool> Function(String tag, String code)? deleteFolder,
  }) : _deleteFolderOverride = deleteFolder,
       _vault = vaultKeys ?? VaultKeys(),
       _targets = targetsStore ?? BackupTargetsStore(),
       _library = library ?? PhotoLibraryService(store: assetRecordStore),
       _removal = removal ?? AssetRemoval(store: assetRecordStore);

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;
  final VaultKeys _vault;
  final BackupTargetsStore _targets;
  final PhotoLibraryService _library;
  final AssetRemoval _removal;
  final Future<bool> Function(String tag, String code)? _deleteFolderOverride;

  Future<PersonDeletionPlan> plan(Set<String> ids) async {
    final members = await personStore.allMemberships();
    final others = {
      for (final MapEntry(key: id, value: photos) in members.entries)
        if (!ids.contains(id)) ...photos,
    };
    final own = {for (final id in ids) ...?members[id]}.difference(others);
    final photos = [
      for (final r in await assetRecordStore.listOf(own))
        if (r.passcodeHash == null && r.deletedAt == null && !r.isLocked) r,
    ];
    final folders = <String, Map<String, String>>{};
    var hidden = 0;
    for (final id in ids) {
      final codes = await personFolderCodes(assetRecordStore, {
        id: await personStore.aliasesOf(id),
      });
      if (codes.isEmpty) continue;
      folders[id] = codes;
      for (final tag in codes.keys) {
        hidden += (await assetRecordStore.forPasscodeHash(tag)).length;
      }
    }
    return (photos: photos, folders: folders, hiddenCount: hidden);
  }

  /// Photos first, people after: a person goes only once their hidden
  /// folders have. Returns the ids deleted.
  Future<Set<String>> run(Set<String> ids, PersonDeletionPlan plan) async {
    for (var at = 0; at < plan.photos.length;) {
      final batch = plan.photos
          .skip(at)
          .take(PhotoLibraryService.deleteBatchLimit)
          .toList();
      await binNow(batch, library: _library, removal: _removal);
      at += batch.length;
    }
    final gone = <String>{};
    for (final id in ids) {
      var emptied = true;
      for (final MapEntry(key: tag, value: code)
          in (plan.folders[id] ?? const <String, String>{}).entries) {
        if (!await _deleteFolder(tag, code)) emptied = false;
      }
      // Their folder's code needs their id: kept until it is empty.
      if (emptied) gone.add(id);
    }
    for (final id in gone) {
      await personStore.remove(id);
    }
    return gone;
  }

  Future<bool> _deleteFolder(String tag, String code) async {
    if (_deleteFolderOverride case final delete?) return delete(tag, code);
    final rows = await assetRecordStore.forPasscodeHash(tag);
    final passphrases = await _vault.entries();
    final keys = passphrases.isEmpty
        ? null
        : await _vault.unlockAlbum(code, tag);
    var entries = const <IndexEntry>[];
    if (keys != null) {
      final known = {
        for (final r in rows) ...[
          vaultCarrierKey(r, keys.carrier),
          ?_relative(r.stateOf(DerivativeKind.original).destinationKey),
        ],
      };
      final gallery = VaultGallery(keys: keys);
      try {
        final listed = await gallery.list();
        final found =
            await HiddenBucketScan(
              store: assetRecordStore,
              targetsStore: _targets,
              bucket: VaultBucket(),
              passphrases: _vault.entries,
            ).find(
              keys,
              known: {...known, for (final e in listed) e.objectKey},
              read: false,
            );
        entries = [
          for (final e in [...listed, ...found])
            if (!known.contains(e.objectKey)) e,
        ];
      } catch (_) {
        // No bucket answer: the rows still go; what the bucket holds is
        // reached through their recorded keys.
      } finally {
        gallery.dispose();
      }
    }
    return HiddenRemoval(
      store: assetRecordStore,
      targetsStore: _targets,
    ).delete(
      keys: keys,
      records: rows,
      entries: entries,
      passphrases: passphrases,
    );
  }

  static String? _relative(String? key) {
    if (key == null) return null;
    final at = key.indexOf('originals/');
    return at == -1 ? key : key.substring(at);
  }
}

/// The confirmation's body: what goes, what stays.
String personDeletionBody(AppLocalizations l10n, PersonDeletionPlan plan) => [
  l10n.personProfileDeleteConfirmBody,
  l10n.personDeletePhotosLine(plan.photos.length),
  if (plan.folders.isNotEmpty) l10n.personDeleteHiddenLine(plan.hiddenCount),
  l10n.personDeleteSharedLine,
].join('\n');
