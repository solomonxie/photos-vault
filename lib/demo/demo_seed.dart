import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../photos/ai_vendor.dart';
import '../photos/image_pipeline.dart';
import '../photos/person_store.dart';
import '../settings/ai_settings_store.dart';
import '../settings/backup_storage_type.dart';
import '../settings/backup_targets_store.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import '../vault/hidden_notes.dart';
import '../vault/keys.dart';
import 'demo_bucket.dart';
import 'demo_flag.dart';
import 'demo_images.dart';

/// Fills the demo library from `demo/seed.json`, once. Only ever runs with
/// [DemoFlag.active], so every store below opens the demo copy.
///
/// Bucket and AI credentials come from `.env.demo`, compiled in by every
/// `make` build (`--dart-define-from-file`) and written only to the demo
/// keychain; without them the demo works offline.
class DemoSeed {
  static const seedAsset = 'demo/seed.json';
  static const _doneKey = 'demo_seeded_v1';

  Future<void> ensure() async {
    if (!DemoFlag.active) return;
    final records = AssetRecordStore();
    if (await records.getAppState(_doneKey) == '1') return;
    final seed = jsonDecode(
      await rootBundle.loadString(seedAsset),
    ) as Map<String, dynamic>;
    final photos = (seed['photos'] as List).cast<Map<String, dynamic>>();

    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'demo_photos'),
    );
    await dir.create(recursive: true);

    // A few at a time, each on its own isolate: drawing is per-pixel work.
    final now = DateTime.now();
    for (var i = 0; i < photos.length; i += 4) {
      await Future.wait([
        for (final photo in photos.skip(i).take(4))
          _addPhoto(records, photo, dir, now),
      ]);
    }

    await _addAlbums(photos);
    await _addPeople(seed, photos);
    await _addHidden(records, seed, photos);
    await _addCredentials();
    await records.setAppState(_doneKey, '1');
  }

  static String localIdOf(Map<String, dynamic> photo) => 'demo:${photo['id']}';

  Future<void> _addPhoto(
    AssetRecordStore records,
    Map<String, dynamic> photo,
    Directory dir,
    DateTime now,
  ) async {
    final id = photo['id'] as String;
    final scene = photo['scene'] as String;
    final bytes = await Isolate.run(
      () => renderDemoPhoto(
        scene: scene,
        // Not String.hashCode, which isn't promised stable across runs.
        seed: id.codeUnits.fold(7, (h, c) => (h * 31 + c) & 0x7fffffff),
      ),
    );
    final file = File(p.join(dir.path, '$id.jpg'));
    await file.writeAsBytes(bytes, flush: true);
    final localId = localIdOf(photo);
    await records.upsert(
      localId: localId,
      contentHash: 'demo-$id',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
      createdAt: DateTime.parse(photo['takenAt'] as String),
      addedAt: now.subtract(
        Duration(days: photo['addedDaysAgo'] as int? ?? 0, minutes: 5),
      ),
      latitude: (photo['latitude'] as num?)?.toDouble(),
      longitude: (photo['longitude'] as num?)?.toDouble(),
      width: 960,
      height: 720,
    );
    final caption = photo['caption'] as String? ?? '';
    if (caption.isNotEmpty) await records.setDescription(localId, caption);
    final tags = (photo['tags'] as List? ?? const []).cast<String>();
    if (tags.isNotEmpty) await records.setTags(localId, tags);
    final place = photo['place'] as String?;
    if (place != null) await records.setLocation(localId, place);
    if (photo['favorite'] == true) await records.setFavorite(localId, true);
    await _setBackup(records, localId, photo['backup'] as String?, bytes, file);
  }

  /// The seed's cloud states, so the grid shows every kind of underline
  /// before any bucket is configured. A real sync takes over from there.
  Future<void> _setBackup(
    AssetRecordStore records,
    String localId,
    String? backup,
    Uint8List bytes,
    File file,
  ) async {
    final key = 'photos-vault/originals/${localId.replaceAll(':', '_')}.jpg';
    final status = switch (backup) {
      'uploaded' || 'cloudOnly' => UploadStatus.uploaded,
      'uploading' => UploadStatus.uploading,
      'failed' => UploadStatus.failed,
      _ => null,
    };
    if (status == null) return;
    await records.updateDerivative(
      localId,
      DerivativeKind.original,
      DerivativeState(status: status, destinationKey: key),
    );
    if (backup != 'cloudOnly') return;
    final thumb = await Isolate.run(() => encodeThumbnail(bytes));
    if (thumb == null) return;
    final thumbFile = File('${file.path}.thumb.jpg');
    await thumbFile.writeAsBytes(thumb, flush: true);
    await records.setThumbnailPath(localId, thumbFile.path);
    await file.delete();
    await records.setLocalDeleted(localId, true);
  }

  Future<void> _addAlbums(List<Map<String, dynamic>> photos) async {
    final albums = AlbumStore();
    final members = <String, List<String>>{};
    for (final photo in photos) {
      for (final name
          in (photo['albums'] as List? ?? const []).cast<String>()) {
        (members[name] ??= []).add(localIdOf(photo));
      }
    }
    for (final MapEntry(key: name, value: ids) in members.entries) {
      final id = 'demo-album-${name.toLowerCase().replaceAll(' ', '-')}';
      await albums.upsert(id: id, name: name);
      await albums.addAssets(id, ids);
    }
  }

  Future<void> _addPeople(
    Map<String, dynamic> seed,
    List<Map<String, dynamic>> photos,
  ) async {
    final people = PersonStore();
    for (final row in (seed['people'] as List).cast<Map<String, dynamic>>()) {
      final name = row['name'] as String;
      final id = 'demo-person-${name.toLowerCase().replaceAll(' ', '-')}';
      final person = await people.create(name: name, id: id);
      await people.update(person.copyWith(bio: row['bio'] as String? ?? ''));
      await people.addAssets(id, [
        for (final photo in photos)
          if ((photo['people'] as List? ?? const []).contains(name))
            localIdOf(photo),
      ]);
    }
  }

  /// A vault with a known passphrase, its album at the seed's code, the
  /// photos marked hidden in it and its notes sealed under its key.
  Future<void> _addHidden(
    AssetRecordStore records,
    Map<String, dynamic> seed,
    List<Map<String, dynamic>> photos,
  ) async {
    final album = seed['hiddenAlbum'] as Map<String, dynamic>?;
    if (album == null) return;
    final passcode = album['passcode'] as String;
    try {
      final keys = VaultKeys();
      if ((await keys.entries()).isEmpty) {
        await keys.add(
          album['passphrase'] as String,
          hint: album['hint'] as String? ?? '',
        );
      }
      for (final photo in photos) {
        if (photo['hidden'] == true) {
          await records.setPasscodeHash(
            localIdOf(photo),
            hashPasscode(passcode),
          );
        }
      }
      final albumKeys = await keys.activeAlbumKeys(passcode);
      if (albumKeys == null) return;
      final notes = HiddenNotes(store: records, keys: albumKeys);
      for (final text in (album['notes'] as List? ?? const []).cast<String>()) {
        await notes.save(text);
      }
    } catch (_) {
      // No keychain or cipher here; the rest of the demo still stands.
    }
  }

  Future<void> _addCredentials() async {
    try {
      const bucket = String.fromEnvironment('DEMO_S3_BUCKET');
      final targets = BackupTargetsStore();
      if ((await targets.loadAll()).isEmpty && bucket.isEmpty) {
        await targets.add(
          accessKeyId: 'DEMO',
          secretAccessKey: 'DEMO',
          region: 'us-west-2',
          bucket: DemoBucket.bucket,
          prefix: DemoBucket.prefix,
        );
      } else if (bucket.isNotEmpty && (await targets.loadAll()).isEmpty) {
        const provider = String.fromEnvironment(
          'DEMO_S3_PROVIDER',
          defaultValue: 's3',
        );
        await targets.add(
          accessKeyId: const String.fromEnvironment('DEMO_S3_ACCESS_KEY_ID'),
          secretAccessKey: const String.fromEnvironment(
            'DEMO_S3_SECRET_ACCESS_KEY',
          ),
          region: const String.fromEnvironment('DEMO_S3_REGION'),
          bucket: bucket,
          prefix: const String.fromEnvironment(
            'DEMO_S3_PREFIX',
            defaultValue: 'photos-vault-demo/',
          ),
          provider: BackupStorageType.values.firstWhere(
            (t) => t.name == provider,
            orElse: () => BackupStorageType.s3,
          ),
        );
      }
      const aiKey = String.fromEnvironment('DEMO_AI_API_KEY');
      final ai = AiSettingsStore();
      if (aiKey.isNotEmpty && (await ai.listKeys()).isEmpty) {
        const vendor = String.fromEnvironment(
          'DEMO_AI_VENDOR',
          defaultValue: 'openai',
        );
        await ai.addKey(
          AiVendor.values.firstWhere(
            (v) => v.name == vendor,
            orElse: () => AiVendor.openai,
          ),
          aiKey,
        );
      }
    } catch (_) {
      // No keychain: the demo runs without a bucket or AI key.
    }
  }
}
