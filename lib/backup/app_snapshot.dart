import 'dart:convert';
import 'dart:io';

import '../photos/ai_analysis_store.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';

/// Everything this app knows that isn't a photo.
///
/// Captions, tags, places, events, albums, people and their profiles, and
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
class AppSnapshot {
  const AppSnapshot({
    required this.version,
    required this.exportedAt,
    required this.assets,
    required this.albums,
    required this.people,
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

  bool get isEmpty => assets.isEmpty && albums.isEmpty && people.isEmpty;

  String encode() => jsonEncode({
    'version': version,
    'exportedAt': exportedAt.toIso8601String(),
    'assets': assets,
    'albums': albums,
    'people': people,
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
  });

  final AssetRecordStore assetRecordStore;
  final AlbumStore albumStore;
  final PersonStore personStore;

  /// Faces, their vectors, and which vendor suggestions were already
  /// answered. Absent, none of that is backed up — which was the case
  /// until it was noticed.
  final AiAnalysisStore? aiAnalysisStore;

  /// The database files behind this app, each checkpointed. What
  /// `LocalVault` copies raw — the one copy that survives a *schema*
  /// problem, which no row-level undo can fix.
  ///
  /// The analysis database joined them late and matters more than its
  /// size suggests: see [AiAnalysisStore.checkpointedFile]. Optional so
  /// the snapshot still stands alone in tests.
  Future<List<File>> databaseFiles() async => [
    ?await assetRecordStore.checkpointedFile(),
    ?await albumStore.checkpointedFile(),
    ?await personStore.checkpointedFile(),
    ?await aiAnalysisStore?.checkpointedFile(),
  ];

  /// One number for "has anything changed", across all three databases.
  /// Summed rather than compared field by field: the gate only ever asks
  /// whether it moved, and a write to any of the three moves it.
  Future<int> changeMark() async =>
      await assetRecordStore.changeMark() +
      await albumStore.changeMark() +
      await personStore.changeMark();

  /// The change log as it travels in the backup zip — one document, the
  /// three databases' logs side by side. Never replayed on restore; it
  /// describes ids that were remapped on the way in.
  Future<Map<String, Object?>> changeLog() async => {
    'assets': await assetRecordStore.changeLogRows(),
    'albums': await albumStore.changeLogRows(),
    'people': await personStore.changeLogRows(),
  };

  Future<AppSnapshot> export() async {
    final records = await assetRecordStore.listAll();
    final albums = <Map<String, Object?>>[];
    for (final album in await albumStore.listAll()) {
      albums.add({
        'id': album.id,
        'name': album.name,
        'createdAt': album.createdAt.toIso8601String(),
        'localIds': await albumStore.localIdsIn(album.id),
      });
    }
    final people = <Map<String, Object?>>[];
    for (final person in await personStore.listAll()) {
      people.add(await _personRow(person));
    }
    return AppSnapshot(
      version: AppSnapshot.currentVersion,
      exportedAt: DateTime.now(),
      assets: records.map(_assetRow).toList(),
      albums: albums,
      people: people,
    );
  }

  Future<int> import(AppSnapshot snapshot) async {
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

  static Map<String, Object?> _assetRow(AssetRecord record) => {
    'localId': record.localId,
    'libraryId': record.libraryId,
    'contentHash': record.contentHash,
    'platform': record.platform,
    'sourceType': record.sourceType.name,
    'sourcePath': record.sourcePath,
    'isVideo': record.isVideo,
    'isLivePhoto': record.isLivePhoto,
    'isGif': record.isGif,
    'createdAt': record.createdAt.toIso8601String(),
    'isFavorite': record.isFavorite,
    'isHidden': record.isHidden,
    'deletedAt': record.deletedAt?.toIso8601String(),
    'localDeleted': record.localDeleted,
    'description': record.description,
    'tags': record.tags,
    'location': record.location,
    'event': record.event,
    'passcodeHash': record.passcodeHash,
    'latitude': record.latitude,
    'longitude': record.longitude,
    'width': record.width,
    'height': record.height,
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
        },
    },
  };

  Future<bool> _importAsset(Map<String, Object?> row) async {
    final localId = row['localId'] as String?;
    if (localId == null || localId.isEmpty) return false;
    if (await assetRecordStore.getByLocalId(localId) != null) return false;
    await assetRecordStore.upsert(
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
      libraryId: row['libraryId'] as String?,
      latitude: (row['latitude'] as num?)?.toDouble(),
      longitude: (row['longitude'] as num?)?.toDouble(),
      width: row['width'] as int?,
      height: row['height'] as int?,
    );
    final description = row['description'] as String? ?? '';
    if (description.isNotEmpty) {
      await assetRecordStore.setDescription(localId, description);
    }
    final tags = (row['tags'] as List<dynamic>? ?? const []).cast<String>();
    if (tags.isNotEmpty) await assetRecordStore.setTags(localId, tags);
    final location = row['location'] as String?;
    if (location != null) await assetRecordStore.setLocation(localId, location);
    final event = row['event'] as String?;
    if (event != null) await assetRecordStore.setEvent(localId, event);
    final passcodeHash = row['passcodeHash'] as String?;
    if (passcodeHash != null) {
      await assetRecordStore.setPasscodeHash(localId, passcodeHash);
    }
    if (row['isFavorite'] as bool? ?? false) {
      await assetRecordStore.setFavorite(localId, true);
    }
    if (row['isHidden'] as bool? ?? false) {
      await assetRecordStore.setHidden(localId, true);
    }
    if (row['localDeleted'] as bool? ?? false) {
      await assetRecordStore.setLocalDeleted(localId, true);
    }
    final deletedAt = _date(row['deletedAt']);
    if (deletedAt != null) await assetRecordStore.softDelete(localId);
    final derivatives = row['derivatives'] as Map<String, Object?>? ?? const {};
    for (final kind in DerivativeKind.values) {
      final state = derivatives[kind.name] as Map<String, Object?>?;
      if (state == null) continue;
      final status = UploadStatus.values.byName(
        state['status'] as String? ?? UploadStatus.pending.name,
      );
      if (status == UploadStatus.pending) continue;
      await assetRecordStore.updateDerivative(
        localId,
        kind,
        DerivativeState(
          status: status,
          destinationKey: state['destinationKey'] as String?,
          backedUpHash: state['backedUpHash'] as String?,
        ),
      );
    }
    return true;
  }

  // ----------------------------------------------------------------- albums

  Future<void> _importAlbum(Map<String, Object?> row) async {
    final id = row['id'] as String?;
    final name = row['name'] as String?;
    if (id == null || name == null) return;
    // The album's own creation date isn't restorable through the store's
    // API, and nothing reads it — albums sort by name.
    await albumStore.upsert(id: id, name: name);
    final localIds = (row['localIds'] as List<dynamic>? ?? const [])
        .cast<String>();
    if (localIds.isNotEmpty) await albumStore.addAssets(id, localIds);
  }

  // ----------------------------------------------------------------- people

  Future<Map<String, Object?>> _personRow(Person person) async {
    final history = <Map<String, Object?>>[];
    for (final category in HistoryCategory.values) {
      for (final entry in await personStore.historyFor(person.id, category)) {
        history.add({
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
        });
      }
    }
    return {
      'id': person.id,
      'name': person.name,
      'createdAt': person.createdAt.toIso8601String(),
      'avatarLocalId': person.avatarLocalId,
      'avatarFace': person.avatarFace?.encode(),
      'bio': person.bio,
      'birthDate': person.birthDate?.toIso8601String(),
      'gender': person.gender?.name,
      'customFields': person.customFields.map((f) => f.toJson()).toList(),
      'locked': person.locked,
      'passcodeHash': person.passcodeHash,
      'passcodeHint': person.passcodeHint,
      'localIds': await personStore.localIdsIn(person.id),
      'locations': [
        for (final location in await personStore.locationsFor(person.id))
          {
            'id': location.id,
            'kind': location.kind.name,
            'place': location.place,
            'since': location.since.toIso8601String(),
          },
      ],
      'history': history,
      'relationships': [
        for (final r in await personStore.relationshipsFor(person.id))
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
      );
    }
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
      );
    }
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}
