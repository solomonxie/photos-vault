import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../photos/ai_analysis_store.dart';
import '../photos/conversation_store.dart';
import '../photos/known_names.dart';
import '../photos/person.dart';
import '../photos/person_detail.dart';
import '../photos/person_store.dart';
import '../photos/record_fixer.dart';
import '../photos/travel_store.dart';
import '../photos/words_store.dart';
import '../storage/album_store.dart';
import '../storage/note.dart';
import '../viewer/built_in_album.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/membership_sweep.dart';
import '../vault/passcode_tags.dart';
import 'change_log.dart';
import 'data_files.dart';

/// Everything this app knows that isn't a photo.
///
/// Captions, tags, places, albums, people and their profiles, and
/// which photo is which person — none of it is in the photo library, none
/// of it is in the bucket alongside the originals, and all of it is gone
/// the moment the app is deleted. The pixels are the one part that *is*
/// safe: they're in Photos, or in a bucket, and copying them again here
/// would turn a few hundred kilobytes into gigabytes.
///
/// Credentials are not in here and never will be — they live in the
/// keychain, which outlives the app on its own. See
/// `docs/design/DESIGN.md`.
///
/// Photos are matched back up by [AssetRecord.localId], which on iOS holds
/// the photo library's own identifier: the library isn't the app's sandbox,
/// so those survive a reinstall on the same device. A record whose photo
/// isn't there is still restored — it carries the work done on it, and the
/// photo may come back from the bucket later.
/// The headline numbers in a snapshot. See [AppSnapshot.summary].
class SnapshotSummary {
  const SnapshotSummary({
    required this.photos,
    required this.people,
    required this.albums,
  });

  final int photos;
  final int people;
  final int albums;
}

class AppSnapshot {
  const AppSnapshot({
    required this.version,
    required this.exportedAt,
    required this.assets,
    required this.albums,
    required this.people,
    this.vault = const {},
    this.dataFiles = const [],
  });

  /// Bumped when the shape changes in a way an older build can't read.
  /// Reading refuses anything newer than it understands rather than
  /// guessing at fields it has never heard of.
  static const currentVersion = 1;

  final int version;
  final DateTime exportedAt;
  final List<Map<String, Object?>> assets;
  final List<Map<String, Object?>> albums;
  final List<Map<String, Object?>> people;

  /// What the private albums keep that is already sealed: album notes and
  /// the passcode-tag key's escrow. Nothing here opens without a
  /// passphrase. Absent from snapshots written before it.
  final Map<String, Object?> vault;

  /// Which blobs held the chats, writings and faces that day — read from
  /// the zip's `data-files.json`, not from `library.json`, so builds that
  /// never heard of it read the rest unchanged. Empty in older backups.
  final List<DataFileEntry> dataFiles;

  AppSnapshot withDataFiles(List<DataFileEntry> files) => AppSnapshot(
    version: version,
    exportedAt: exportedAt,
    assets: assets,
    albums: albums,
    people: people,
    vault: vault,
    dataFiles: files,
  );

  bool get isEmpty => assets.isEmpty && albums.isEmpty && people.isEmpty;

  /// What is in here, for the line the restore dialog shows before it asks.
  ///
  /// Two copies taken a week apart look identical otherwise — same file
  /// naming, same size to the eye — and the question anybody actually has in
  /// front of a list of them is which one holds more of their library.
  ///
  /// [photos] is the library count: what would show in the grid. Photos in
  /// the bin are left out because they are not in the library, and hidden
  /// ones because a number that moved when you hid something would be one
  /// more thing answering the question the private album exists not to
  /// answer.
  SnapshotSummary get summary {
    var photos = 0;
    for (final asset in assets) {
      if (asset['deletedAt'] != null) continue;
      if (asset['isHidden'] as bool? ?? false) continue;
      if (asset['passcodeHash'] != null) continue;
      photos++;
    }
    return SnapshotSummary(
      photos: photos,
      people: people.length,
      // Built-in albums' notes ride as rows; they aren't albums restored.
      albums: albums.where((a) => a['builtIn'] != true).length,
    );
  }

  String encode() => jsonEncode({
    'version': version,
    'exportedAt': exportedAt.toIso8601String(),
    'assets': assets,
    'albums': albums,
    'people': people,
    if (vault.isNotEmpty) 'vault': vault,
  });

  /// `null` for anything that isn't a snapshot this build can read — a
  /// truncated file, or one written by a newer version.
  static AppSnapshot? decode(String source) {
    try {
      final json = jsonDecode(source) as Map<String, Object?>;
      final version = json['version'] as int? ?? 0;
      if (version < 1 || version > currentVersion) return null;
      return AppSnapshot(
        version: version,
        exportedAt:
            DateTime.tryParse(json['exportedAt'] as String? ?? '') ??
            DateTime.now(),
        assets: _rows(json['assets']),
        albums: _rows(json['albums']),
        people: _rows(json['people']),
        vault: json['vault'] as Map<String, Object?>? ?? const {},
      );
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, Object?>> _rows(Object? value) =>
      (value as List<dynamic>? ?? const [])
          .whereType<Map<String, Object?>>()
          .toList();
}

/// Reads every store into one [AppSnapshot], and writes one back.
///
/// Restoring only ever *adds*: a photo already tracked keeps what it has.
/// The one caller is a fresh install with nothing to overwrite (see
/// `ICloudBackup`), and that's the shape that makes running it twice
/// harmless.
class AppSnapshotIo {
  AppSnapshotIo({
    required this.assetRecordStore,
    required this.albumStore,
    required this.personStore,
    this.aiAnalysisStore,
    this.hasAsset,
    this.conversationStore,
    this.wordsStore,
    this.travelStore,
    this.supportDirectory,
  });

  /// Chats and writings: outside `library.json`, backed up as blobs.
  /// See `data_files.dart`.
  final ConversationStore? conversationStore;
  final WordsStore? wordsStore;

  /// The travel diary: places, entries, routes.
  final TravelStore? travelStore;

  /// Where `words/media` is; overridable so a test never asks iOS.
  final Future<Directory> Function()? supportDirectory;

  late final DataFiles dataFiles = DataFiles(
    conversations: conversationStore,
    words: wordsStore,
    travel: travelStore,
    analysis: aiAnalysisStore,
    supportDirectory: supportDirectory,
  );

  /// The day's blobs, staged. The caller disposes the set.
  Future<DataFileSet> collectDataFiles() async =>
      dataFiles.collect(hiddenIds: await assetRecordStore.hiddenIds());

  /// After a restore's rows: the chats, writings and faces its zip listed,
  /// fetched through [fetch]. Never throws; returns how many came back.
  Future<int> restoreDataFiles(AppSnapshot snapshot, BlobFetch fetch) async {
    try {
      return await dataFiles.restore(snapshot.dataFiles, fetch);
    } catch (_) {
      return 0;
    }
  }

  /// Whether Photos on this phone has an asset id (null: couldn't tell).
  /// Without it a restored row never takes over a scanned twin by shape.
  final Future<bool?> Function(String libraryId)? hasAsset;

  final AssetRecordStore assetRecordStore;
  final AlbumStore albumStore;
  final PersonStore personStore;

  /// Faces and their vectors. Absent, none of that is backed up — which was the case
  /// until it was noticed.
  final AiAnalysisStore? aiAnalysisStore;

  /// Copies of the databases behind this app into [directory], as
  /// `<lead>-<name>.db` — what `LocalVault` keeps, the one copy that
  /// survives a *schema* problem, which no row-level undo can fix.
  ///
  /// `VACUUM INTO`, not a file copy: consistent while open, and no free
  /// pages holding deleted rows. Nothing behind a passcode goes in: hidden
  /// rows, their uploads, memberships, faces. The analysis database joined
  /// late and matters more than its size suggests: see
  /// [AiAnalysisStore.copyTo]. Returns how many were written. [slim]: the
  /// daily copy, without what a restore rebuilds (see
  /// [AssetRecordStore.copyTo]).
  Future<int> copyDatabases(
    String directory,
    String lead, {
    bool slim = false,
    bool withChats = true,
  }) async {
    final hidden = await assetRecordStore.hiddenIds();
    String at(String name) => p.join(directory, '$lead-$name.db');
    final copies = [
      assetRecordStore.copyTo(at('photos_vault'), slim: slim),
      albumStore.copyTo(at('photo_albums'), hidden, slim: slim),
      personStore.copyTo(at('people'), hidden, slim: slim),
      ?aiAnalysisStore?.copyTo(at('ai_analysis'), hidden),
      if (withChats) ?conversationStore?.copyTo(at('conversations')),
      if (withChats) ?wordsStore?.copyTo(at('words')),
      ?travelStore?.copyTo(at('travel')),
    ];
    var written = 0;
    for (final copy in copies) {
      if (await copy) written++;
    }
    return written;
  }

  /// One number for "has anything changed", across all three databases.
  /// Summed rather than compared field by field: the gate only ever asks
  /// whether it moved, and a write to any of the three moves it.
  Future<int> changeMark() async =>
      await assetRecordStore.changeMark() +
      await albumStore.changeMark() +
      await personStore.changeMark() +
      // Chats, writings and faces keep no change log: their own marks.
      await dataFiles.mark();

  /// The change log as it travels in the backup zip — one document, the
  /// three databases' logs side by side. Never replayed on restore; it
  /// describes ids that were remapped on the way in.
  ///
  /// Entries naming a hidden photo are left out; the stores already log
  /// nothing of rows behind a passcode.
  Future<Map<String, Object?>> changeLog() async =>
      (await rawChangeLog()).open();

  /// [changeLog] as read, JSON undecoded: [RawChangeLog.open] is the
  /// expensive half, for the isolate that builds the zip.
  Future<RawChangeLog> rawChangeLog() async => RawChangeLog(
    hidden: await assetRecordStore.hiddenIds(),
    assets: await assetRecordStore.changeLogRows(decode: false),
    albums: await albumStore.changeLogRows(decode: false),
    people: await personStore.changeLogRows(decode: false),
  );

  late final PasscodeTags _tags = PasscodeTags(
    records: assetRecordStore,
    people: personStore,
  );

  /// Hidden photos are left out entirely — row, tag, carrier keys and
  /// memberships. A new phone gets them back from the buckets' carriers
  /// (album index, or Find in Bucket) with the passphrase and code; their
  /// captions and tags stay on this phone.
  Future<AppSnapshot> export() async {
    final all = await assetRecordStore.listAll();
    final hidden = {
      for (final r in all)
        if (r.passcodeHash != null) r.localId,
    };
    final records = [
      for (final r in all)
        if (r.passcodeHash == null) r,
    ];
    List<String> shown(List<String> ids) =>
        hidden.isEmpty ? ids : [...ids.where((id) => !hidden.contains(id))];
    final uploads = <String, List<Map<String, Object?>>>{};
    for (final row in await assetRecordStore.uploadRows()) {
      if (hidden.contains(row['local_id'])) continue;
      (uploads[row['local_id'] as String] ??= []).add({
        'kind': row['kind'],
        'targetId': row['target_id'],
        'key': row['destination_key'],
        'sourceHash': row['source_hash'],
      });
    }
    final albums = <Map<String, Object?>>[];
    final albumMembers = await albumStore.allMemberships();
    for (final album in await albumStore.listAll()) {
      albums.add({
        'id': album.id,
        'name': album.name,
        'createdAt': album.createdAt.toIso8601String(),
        'localIds': shown(albumMembers[album.id] ?? const <String>[]),
        'notes': [
          for (final note in await albumStore.notes(album.id)) _noteRow(note),
        ],
      });
    }
    // Built-in albums aren't rows, but their notes are kept like an album's.
    for (final builtIn in BuiltInAlbum.values) {
      final notes = await albumStore.notes(builtIn.id);
      if (notes.isEmpty) continue;
      albums.add({
        'id': builtIn.id,
        'builtIn': true,
        'notes': [for (final note in notes) _noteRow(note)],
      });
    }
    final people = <Map<String, Object?>>[];
    final personMembers = await personStore.allMemberships();
    final sets = await personStore.exportSets();
    final knownAs = <String, List<KnownAs>>{};
    for (final k in await personStore.allKnownAs()) {
      (knownAs[k.personId] ??= []).add(k);
    }
    for (final person in await personStore.listAll()) {
      final row = _personRow(
        person,
        shown(personMembers[person.id] ?? const <String>[]),
        sets[person.id] ?? PersonExportSet(),
      );
      if (knownAs[person.id] case final known?) {
        row['knownAs'] = [
          for (final k in known) {'kind': k.kind, 'value': k.value},
        ];
      }
      if (hidden.contains(person.avatarLocalId)) {
        row['avatarLocalId'] = null;
        row['avatarFace'] = null;
      }
      people.add(row);
    }
    return AppSnapshot(
      version: AppSnapshot.currentVersion,
      exportedAt: DateTime.now(),
      assets: [
        for (final r in records) _assetRow(r, uploads[r.localId] ?? const []),
      ],
      albums: albums,
      people: people,
      vault: {
        'hiddenNotes': await assetRecordStore.allHiddenNoteRows(),
        'tagEscrow': await _tags.exportEscrows(),
      },
    );
  }

  Future<int> import(AppSnapshot snapshot) =>
      RestoreGuard.run(() => _import(snapshot));

  /// Nothing here a restore could overwrite: no album, no person, and no
  /// record. With [scannedRows] — a launch that began on an empty library —
  /// records a scan of Photos made since are allowed, so long as they carry
  /// nothing anybody did: the import merges with them.
  Future<bool> isFreshInstall({bool scannedRows = false}) async {
    if ((await albumStore.listAll()).isNotEmpty) return false;
    if ((await personStore.listAll()).isNotEmpty) return false;
    final records = await assetRecordStore.listAll();
    return scannedRows ? records.every(carriesNothing) : records.isEmpty;
  }

  /// A row only a scan wrote: nothing on it to lose to a merge.
  static bool carriesNothing(AssetRecord r) =>
      r.sourceType == AssetSourceType.photoManager &&
      r.passcodeHash == null &&
      !r.isHidden &&
      !r.isLocked &&
      !r.isArchived &&
      !r.isDeleted &&
      !r.localDeleted &&
      r.description.isEmpty &&
      r.tags.isEmpty &&
      r.location == null &&
      DerivativeKind.values.every((k) {
        final state = r.stateOf(k);
        return state.status != UploadStatus.uploaded &&
            state.destinationKey == null;
      });

  Future<int> _import(AppSnapshot snapshot) async {
    var restored = 0;
    for (final row in snapshot.assets) {
      if (await _importAsset(row)) restored++;
    }
    for (final row in snapshot.albums) {
      await _importAlbum(row);
    }
    for (final row in snapshot.people) {
      await _importPerson(row);
    }
    // Relationships go in a second pass: both ends have to exist first.
    for (final row in snapshot.people) {
      await _importRelationships(row);
    }
    for (final note in _rowsOf(snapshot.vault['hiddenNotes'])) {
      await assetRecordStore.restoreHiddenNote(note);
    }
    await _tags.importEscrows(_rowsOf(snapshot.vault['tagEscrow']));
    return restored;
  }

  /// Clears the data represented by an app-data snapshot. Credentials and
  /// backup destinations deliberately live outside this boundary.
  Future<void> clearAll() async {
    await Future.wait([
      assetRecordStore.clearAll(),
      albumStore.clearAll(),
      personStore.clearAll(),
      if (aiAnalysisStore != null) aiAnalysisStore!.clearAll(),
    ]);
  }

  // ----------------------------------------------------------------- assets

  static Map<String, Object?> _assetRow(
    AssetRecord record,
    List<Map<String, Object?>> uploads,
  ) => {
    'localId': record.localId,
    'libraryId': record.libraryId,
    'contentHash': record.contentHash,
    'platform': record.platform,
    'sourceType': record.sourceType.name,
    'sourcePath': record.sourcePath,
    'isVideo': record.isVideo,
    'isLivePhoto': record.isLivePhoto,
    'hasEdit': record.hasEdit,
    'isGif': record.isGif,
    'createdAt': record.createdAt.toIso8601String(),
    'addedAt': record.addedAt.toIso8601String(),
    'isFavorite': record.isFavorite,
    'isHidden': record.isHidden,
    if (record.isArchived) 'isArchived': true,
    if (record.peopleOnly) 'peopleOnly': true,
    'deletedAt': record.deletedAt?.toIso8601String(),
    if (record.binnedByLibrary) 'binnedByLibrary': true,
    'localDeleted': record.localDeleted,
    'description': record.description,
    'tags': record.tags,
    'location': record.location,
    'passcodeHash': record.passcodeHash,
    'latitude': record.latitude,
    'longitude': record.longitude,
    'width': record.width,
    'height': record.height,
    // Which bucket holds which key. The record's one key carries the first
    // bucket's prefix; without these rows a restored library can't tell
    // another bucket's copy from a guess, and a delete against it is a 404
    // that reads as "gone" while the object stays.
    'uploads': uploads,
    // Where each derivative landed. Not user-authored, and by the letter of
    // "don't back up what a sync rebuilds" it doesn't belong — except that
    // rebuilding it means uploading the whole library a second time, which
    // is not a cost anyone would accept for a metadata restore.
    'derivatives': {
      for (final kind in DerivativeKind.values)
        kind.name: {
          'status': record.stateOf(kind).status.name,
          'destinationKey': record.stateOf(kind).destinationKey,
          'backedUpHash': record.stateOf(kind).backedUpHash,
          if (record.stateOf(kind).fromResource) 'fromResource': true,
        },
    },
  };

  /// One restored row. A scan that got there first is merged with, never
  /// overwritten: same id, the backup fills what the scanned row lacks; the
  /// same asset (or, from another phone, its twin by capture time and
  /// shape) under another id, the restored row takes the asset over. A row
  /// carrying anything of its own is left alone.
  Future<bool> _importAsset(Map<String, Object?> row) async {
    final localId = row['localId'] as String?;
    if (localId == null || localId.isEmpty) return false;
    final existing = await assetRecordStore.getByLocalId(localId);
    if (existing != null) {
      if (!carriesNothing(existing)) return false;
      await _fill(existing, row, fresh: false);
      return true;
    }
    final libraryId = row['libraryId'] as String?;
    final inserted = await assetRecordStore.upsert(
      localId: localId,
      contentHash: row['contentHash'] as String? ?? localId,
      platform: row['platform'] as String? ?? 'ios',
      sourceType: AssetSourceType.values.byName(
        row['sourceType'] as String? ?? AssetSourceType.photoManager.name,
      ),
      // Deliberately dropped: an absolute path into the *old* container,
      // which iOS has already deleted. `AssetRecordStore` re-finds a
      // manually-added file by name under the current one.
      sourcePath: null,
      isVideo: row['isVideo'] as bool? ?? false,
      isLivePhoto: row['isLivePhoto'] as bool? ?? false,
      isGif: row['isGif'] as bool? ?? false,
      createdAt: _date(row['createdAt']),
      addedAt: _date(row['addedAt']),
      libraryId: libraryId,
      // Its asset already held here: kept unlinked, metadata and all, until
      // [_takeOverScanned] decides.
      keepOnLibraryConflict: true,
      latitude: (row['latitude'] as num?)?.toDouble(),
      longitude: (row['longitude'] as num?)?.toDouble(),
      width: row['width'] as int?,
      height: row['height'] as int?,
    );
    await _fill(inserted, row, fresh: true);
    if (inserted.sourceType == AssetSourceType.photoManager &&
        row['passcodeHash'] == null) {
      await _takeOverScanned(inserted, libraryId);
    }
    return true;
  }

  /// The scanned record on this row's asset, folded into it. When none is
  /// found the row waits for the scan to bring its asset (another phone
  /// gives it a new id: see `PhotoLibraryService`).
  Future<void> _takeOverScanned(AssetRecord restored, String? libraryId) async {
    if (libraryId == null) return;
    final found = await assetRecordStore.getByLibraryId(libraryId);
    final holder = found?.localId == restored.localId ? null : found;
    if (holder != null) {
      if (carriesNothing(holder)) {
        await assetRecordStore.adoptAsset(restored.localId, libraryId);
      }
      return;
    }
    if (await hasAsset?.call(libraryId) == false) {
      final twin = await assetRecordStore.scannedTwin(
        createdAt: restored.createdAt,
        isVideo: restored.isVideo,
        width: restored.width,
        height: restored.height,
        except: restored.localId,
      );
      final twinAsset = twin?.libraryId;
      if (twin != null && twinAsset != null && carriesNothing(twin)) {
        if (await assetRecordStore.adoptAsset(restored.localId, twinAsset)) {
          return;
        }
      }
    }
    await assetRecordStore.markRelinkPending(
      restored.localId,
      restored.createdAt,
    );
  }

  /// What the backup says about [current] and [current] doesn't: blanks
  /// filled, nothing replaced. [fresh] is a row this restore just made;
  /// otherwise a scan made it from the photo as it is in Photos now, so
  /// "cloud-only" and "binned because Photos lost it" are stale.
  Future<void> _fill(
    AssetRecord current,
    Map<String, Object?> row, {
    required bool fresh,
  }) async {
    final localId = current.localId;
    final description = row['description'] as String? ?? '';
    if (description.isNotEmpty && current.description.isEmpty) {
      await assetRecordStore.setDescription(localId, description);
    }
    final tags = (row['tags'] as List<dynamic>? ?? const []).cast<String>();
    if (tags.any((t) => !current.tags.contains(t))) {
      await assetRecordStore.setTags(
        localId,
        {...current.tags, ...tags}.toList(),
      );
    }
    final location = row['location'] as String?;
    if (location != null && current.location == null) {
      await assetRecordStore.setLocation(localId, location);
    }
    // Only in snapshots from before hidden rows were left out. Its old-form
    // tag still opens the album, and is upgraded the first time it does.
    final passcodeHash = row['passcodeHash'] as String?;
    if (passcodeHash != null && current.passcodeHash == null) {
      await assetRecordStore.setPasscodeHash(localId, passcodeHash);
      await RecordFixer.forgetPrints([localId]);
    }
    if ((row['isFavorite'] as bool? ?? false) && !current.isFavorite) {
      await assetRecordStore.setFavorite(localId, true);
    }
    if ((row['isArchived'] as bool? ?? false) && !current.isArchived) {
      await assetRecordStore.setArchived([localId], true);
    }
    if (row['peopleOnly'] as bool? ?? false) {
      await assetRecordStore.setPeopleOnly([localId], true);
    }
    if ((row['isHidden'] as bool? ?? false) && !current.isHidden) {
      await assetRecordStore.setHidden(localId, true);
    }
    if (fresh && (row['localDeleted'] as bool? ?? false)) {
      await assetRecordStore.setLocalDeleted(localId, true);
    }
    final byLibrary = row['binnedByLibrary'] as bool? ?? false;
    if (_date(row['deletedAt']) != null &&
        !current.isDeleted &&
        (fresh || !byLibrary)) {
      await assetRecordStore.softDelete(localId, byLibrary: byLibrary);
    }
    final filled = <DerivativeKind>{};
    final derivatives = row['derivatives'] as Map<String, Object?>? ?? const {};
    for (final kind in DerivativeKind.values) {
      final state = derivatives[kind.name] as Map<String, Object?>?;
      if (state == null) continue;
      final status = UploadStatus.values.byName(
        state['status'] as String? ?? UploadStatus.pending.name,
      );
      if (status == UploadStatus.pending) continue;
      if (current.stateOf(kind).status != UploadStatus.pending) continue;
      filled.add(kind);
      await assetRecordStore.updateDerivative(
        localId,
        kind,
        DerivativeState(
          status: status,
          destinationKey: state['destinationKey'] as String?,
          backedUpHash: state['backedUpHash'] as String?,
          fromResource: state['fromResource'] == true,
        ),
      );
    }
    // So a restore brings the edit back, and the photo never counts as
    // backed up whole without it.
    if ((row['hasEdit'] as bool? ?? false) &&
        !current.hasEdit &&
        (fresh || filled.contains(DerivativeKind.edited))) {
      await assetRecordStore.setHasEdit(localId, true);
    }
    for (final upload
        in (row['uploads'] as List<dynamic>? ?? const [])
            .whereType<Map<String, Object?>>()) {
      final kind = DerivativeKind.values.asNameMap()[upload['kind']];
      final key = upload['key'] as String?;
      if (kind == null || key == null) continue;
      // A merged row keeps its own uploads; a fresh one takes every key.
      if (!fresh && !filled.contains(kind)) continue;
      await assetRecordStore.recordUpload(
        localId: localId,
        kind: kind,
        targetId: upload['targetId'] as String? ?? '',
        destinationKey: key,
        sourceHash: upload['sourceHash'] as String?,
      );
    }
  }

  // ----------------------------------------------------------------- albums

  static Map<String, Object?> _noteRow(Note note) => {
    'id': note.id,
    'text': note.text,
    'createdAt': note.createdAt.toIso8601String(),
    'updatedAt': note.updatedAt.toIso8601String(),
  };

  Future<void> _importAlbum(Map<String, Object?> row) async {
    final id = row['id'] as String?;
    if (id != null && row['builtIn'] == true) {
      await _importNotes(id, row);
      return;
    }
    final name = row['name'] as String?;
    if (id == null || name == null) return;
    // The album's own creation date isn't restorable through the store's
    // API, and nothing reads it — albums sort by name.
    await albumStore.upsert(id: id, name: name);
    final localIds = (row['localIds'] as List<dynamic>? ?? const [])
        .cast<String>();
    if (localIds.isNotEmpty) await albumStore.addAssets(id, localIds);
    await _importNotes(id, row);
  }

  Future<void> _importNotes(String id, Map<String, Object?> row) async {
    for (final note in _rowsOf(row['notes'])) {
      final noteId = note['id'] as String?;
      final text = note['text'] as String?;
      if (noteId == null || text == null) continue;
      final created =
          DateTime.tryParse(note['createdAt'] as String? ?? '') ??
          DateTime.now();
      await albumStore.putNote(
        id,
        Note(
          id: noteId,
          text: text,
          createdAt: created,
          updatedAt:
              DateTime.tryParse(note['updatedAt'] as String? ?? '') ?? created,
        ),
      );
    }
  }

  // ----------------------------------------------------------------- people

  Map<String, Object?> _personRow(
    Person person,
    List<String> localIds,
    PersonExportSet set,
  ) {
    // The open set. What is kept behind a passcode goes out sealed, under
    // `sealed` below — it cannot be read here and must not be lost either.
    final detail = set.detail;
    final history = [
      for (final entry in set.history)
        {
          'id': entry.id,
          'category': entry.category.name,
          'title': entry.title,
          'startDate': entry.startDate?.toIso8601String(),
          'endDate': entry.endDate?.toIso8601String(),
          'notes': entry.notes,
          'customFields': entry.customFields.map((f) => f.toJson()).toList(),
          'titles': entry.titles.map((t) => t.toJson()).toList(),
          'projects': entry.projects.map((p) => p.toJson()).toList(),
          'awards': entry.awards.map((a) => a.toJson()).toList(),
        },
    ];
    return {
      'id': person.id,
      'name': person.name,
      'createdAt': person.createdAt.toIso8601String(),
      'avatarLocalId': person.avatarLocalId,
      'avatarFace': person.avatarFace?.encode(),
      'bio': detail.bio,
      'birthDate': detail.birthDate?.toIso8601String(),
      'gender': detail.gender?.name,
      'customFields': detail.customFields.map((f) => f.toJson()).toList(),
      'impression': detail.impression.toJson(),
      'sealed': set.sealed,
      'localIds': localIds,
      'locations': [
        for (final location in set.locations)
          {
            'id': location.id,
            'kind': location.kind.name,
            'place': location.place,
            'since': location.since.toIso8601String(),
          },
      ],
      'history': history,
      'relationships': [
        for (final r in set.relationships)
          {
            'relatedPersonId': r.relatedPersonId,
            'type': r.type.name,
            'organization': r.organization,
          },
      ],
    };
  }

  Future<void> _importPerson(Map<String, Object?> row) async {
    final id = row['id'] as String?;
    final name = row['name'] as String?;
    if (id == null || name == null) return;
    await _importPersonDetail(id, row);
    final person = await personStore.create(name: name, id: id);
    await personStore.update(
      person.copyWith(
        name: name,
        avatarLocalId: row['avatarLocalId'] as String?,
        avatarFace: () => FaceRect.decode(row['avatarFace'] as String?),
        bio: row['bio'] as String? ?? '',
        birthDate: () => _date(row['birthDate']),
        gender: () {
          final gender = row['gender'] as String?;
          return gender == null ? null : Gender.values.byName(gender);
        },
        customFields: (row['customFields'] as List<dynamic>? ?? const [])
            .whereType<Map<String, Object?>>()
            .map(PersonCustomField.fromJson)
            .toList(),
        locked: row['locked'] as bool? ?? false,
        passcodeHash: () => row['passcodeHash'] as String?,
        passcodeHint: () => row['passcodeHint'] as String?,
      ),
    );
    final localIds = (row['localIds'] as List<dynamic>? ?? const [])
        .cast<String>();
    if (localIds.isNotEmpty) await personStore.addAssets(id, localIds);
    for (final location
        in (row['locations'] as List<dynamic>? ?? const [])
            .whereType<Map<String, Object?>>()) {
      await personStore.addLocation(
        PersonLocation(
          id: location['id'] as String? ?? personStore.newId(),
          personId: id,
          kind: LocationKind.values.byName(
            location['kind'] as String? ?? LocationKind.origin.name,
          ),
          place: location['place'] as String? ?? '',
          since: _date(location['since']) ?? DateTime.now(),
        ),
        scope: PersonScope.open,
      );
    }
    for (final entry
        in (row['history'] as List<dynamic>? ?? const [])
            .whereType<Map<String, Object?>>()) {
      await personStore.addHistoryEntry(
        PersonHistoryEntry(
          id: entry['id'] as String? ?? personStore.newId(),
          personId: id,
          category: HistoryCategory.values.byName(
            entry['category'] as String? ?? HistoryCategory.job.name,
          ),
          title: entry['title'] as String? ?? '',
          startDate: _date(entry['startDate']),
          endDate: _date(entry['endDate']),
          notes: entry['notes'] as String? ?? '',
          customFields: (entry['customFields'] as List<dynamic>? ?? const [])
              .whereType<Map<String, Object?>>()
              .map(PersonCustomField.fromJson)
              .toList(),
          titles: (entry['titles'] as List<dynamic>? ?? const [])
              .whereType<Map<String, Object?>>()
              .map(TimelineEntry.fromJson)
              .toList(),
          projects: (entry['projects'] as List<dynamic>? ?? const [])
              .whereType<Map<String, Object?>>()
              .map(CareerProject.fromJson)
              .toList(),
          awards: (entry['awards'] as List<dynamic>? ?? const [])
              .whereType<Map<String, Object?>>()
              .map(TimelineEntry.fromJson)
              .toList(),
        ),
        scope: PersonScope.open,
      );
    }
    await personStore.rememberKnownAs([
      for (final k
          in (row['knownAs'] as List<dynamic>? ?? const [])
              .whereType<Map<String, Object?>>())
        if ((k['kind'], k['value']) case (final String kind, final String v))
          KnownAs(personId: id, kind: kind, value: v),
    ]);
  }

  /// The open set, and whatever was kept behind a passcode.
  ///
  /// The sealed rows go back exactly as they came out. This phone may not be
  /// able to open any of them — a different passphrase, or one forgotten
  /// since — and that is not a reason to drop somebody's data on restore.
  Future<void> _importPersonDetail(String id, Map<String, Object?> row) async {
    final birth = row['birthDate'] as String?;
    final gender = row['gender'] as String?;
    await personStore.saveDetail(
      id,
      PersonDetail(
        bio: row['bio'] as String? ?? '',
        birthDate: birth == null ? null : DateTime.tryParse(birth),
        gender: Gender.values.where((g) => g.name == gender).firstOrNull,
        customFields: [
          for (final f in (row['customFields'] as List? ?? const []))
            PersonCustomField.fromJson((f as Map).cast<String, Object?>()),
        ],
        impression: PersonImpression.fromJson(
          ((row['impression'] as Map?) ?? const {}).cast<String, Object?>(),
        ),
      ),
      scope: PersonScope.open,
    );
    final sealed = row['sealed'] as List?;
    if (sealed == null || sealed.isEmpty) return;
    await personStore.restoreSealedRows([
      for (final r in sealed) (r as Map).cast<String, Object?>(),
    ]);
  }

  Future<void> _importRelationships(Map<String, Object?> row) async {
    final id = row['id'] as String?;
    if (id == null) return;
    for (final relationship
        in (row['relationships'] as List<dynamic>? ?? const [])
            .whereType<Map<String, Object?>>()) {
      final relatedId = relationship['relatedPersonId'] as String?;
      if (relatedId == null) continue;
      if (await personStore.getById(relatedId) == null) continue;
      await personStore.addRelationship(
        id,
        relatedId,
        RelationshipType.values.byName(
          relationship['type'] as String? ?? RelationshipType.other.name,
        ),
        organization: relationship['organization'] as String?,
        scope: PersonScope.open,
      );
    }
  }

  static List<Map<String, Object?>> _rowsOf(Object? value) => [
    for (final row in value as List? ?? const [])
      if (row is Map) row.cast<String, Object?>(),
  ];

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

/// The three logs' tails with `before`/`after` still JSON text.
class RawChangeLog {
  const RawChangeLog({
    required this.hidden,
    required this.assets,
    required this.albums,
    required this.people,
  });

  final Set<String> hidden;
  final List<Map<String, Object?>> assets;
  final List<Map<String, Object?>> albums;
  final List<Map<String, Object?>> people;

  /// Decoded, without entries naming a hidden photo.
  Map<String, Object?> open() {
    bool tagged(Object? side) =>
        side is Map && '${side['passcode_hash'] ?? ''}'.isNotEmpty;
    List<Map<String, Object?>> keep(List<Map<String, Object?>> rows) => [
      for (final row in rows.map(decodeChangeLogRow))
        if (!tagged(row['before']) &&
            !tagged(row['after']) &&
            !'${row['row_key']}'.split('/').any(hidden.contains))
          row,
    ];
    return {
      'assets': keep(assets),
      'albums': keep(albums),
      'people': keep(people),
    };
  }
}
