import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import '../vault/plain_files.dart';
import 'manual_add.dart';
import 'person_store.dart';
import 'profile_csv.dart';
import 'profile_transfer.dart';

/// A people archive: `people.csv` (the Export to CSV columns) and
/// `photos/<name>/<file>`, a folder per person named as the row's `name`.
/// See `docs/design/people-zip-import/DESIGN.md`.
class PeopleZip {
  PeopleZip._(this.dir, this.people, this.skipped);

  /// Where it was unpacked; [discard] removes it.
  final Directory dir;
  final List<PeopleZipPerson> people;

  /// Entries that are neither the CSV nor a photo in a person's folder.
  final int skipped;

  static const photoExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.bmp',
    '.webp',
    '.heic',
    '.heif',
    '.mov',
    '.mp4',
  };

  /// Unpacks [zipPath] into a fresh folder under [workDir], off the UI
  /// isolate: entries stream to disk one at a time, never the whole zip in
  /// memory.
  static Future<PeopleZip> open(String zipPath, Directory workDir) async {
    final dir = await workDir.createTemp('people-zip-');
    try {
      return await Isolate.run(() => _unpack(zipPath, dir.path));
    } catch (_) {
      await dir.delete(recursive: true);
      rethrow;
    }
  }

  static Future<PeopleZip> _unpack(String zipPath, String into) async {
    await extractFileToDisk(zipPath, into);
    final root = Directory(into);
    final profiles = <String, ProfileCsvRow>{};
    final photos = <String, List<String>>{};
    var skipped = 0;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.split(p.relative(entity.path, from: into));
      final base = rel.last;
      if (base.startsWith('.') || rel.contains('__MACOSX')) continue;
      if (rel.length == 1 && base.toLowerCase().endsWith('.csv')) {
        for (final row in readProfileCsv(
          _decode(entity.readAsBytesSync()),
        ).rows) {
          profiles[row.name.trim().toLowerCase()] = row;
        }
      } else if (rel.length == 3 &&
          rel.first == 'photos' &&
          photoExtensions.contains(p.extension(base).toLowerCase())) {
        (photos[rel[1]] ??= []).add(entity.path);
      } else {
        skipped++;
      }
    }
    // One person per name, ignoring case: a folder "alice" is the CSV's
    // "Alice", as matching to people here already is.
    final names = <String, String>{
      for (final folder in photos.keys) folder.trim().toLowerCase(): folder,
      for (final row in profiles.values)
        row.name.trim().toLowerCase(): row.name.trim(),
    };
    final photosOf = <String, List<String>>{};
    for (final MapEntry(:key, :value) in photos.entries) {
      (photosOf[key.trim().toLowerCase()] ??= []).addAll(value);
    }
    final people = [
      for (final MapEntry(key: lower, value: name)
          in names.entries.toList()..sort((a, b) => a.value.compareTo(b.value)))
        PeopleZipPerson(
          name: name,
          profile: profiles[lower],
          photos: (photosOf[lower] ?? <String>[])..sort(),
        ),
    ];
    return PeopleZip._(root, people, skipped);
  }

  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }

  Future<void> discard() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

class PeopleZipPerson {
  const PeopleZipPerson({
    required this.name,
    required this.photos,
    this.profile,
  });

  final String name;
  final ProfileCsvRow? profile;

  /// Paths in the unpacked folder.
  final List<String> photos;
}

/// What to do with one person: in or out, hidden or not, and which of
/// their photos.
class PeopleZipPick {
  PeopleZipPick(this.person)
    : photos = {...person.photos},
      include = true,
      hide = false;

  final PeopleZipPerson person;
  bool include;
  bool hide;
  final Set<String> photos;

  /// Set when the name is more than one person here (see [PersonMatches]).
  PersonTarget? target;
}

class PeopleZipResult {
  const PeopleZipResult({
    this.people = 0,
    this.visible = 0,
    this.hidden = 0,
    this.failed = 0,
  });

  final int people;
  final int visible;
  final int hidden;
  final int failed;
}

/// Writes the picked people and photos. Visible photos land in Archive,
/// tagged to their person; hidden ones are born hidden in the person's own
/// folder ([personAlbumCode]) and tagged to nobody, like every hidden
/// photo. Re-importing is a no-op per photo: ids come from content.
class PeopleZipImporter {
  PeopleZipImporter({
    required this.personStore,
    required this.recordStore,
    required this.tagFor,
    ManualAddService? manualAdd,
    PlainFiles? plainFiles,
  }) : _manualAdd = manualAdd ?? ManualAddService(store: recordStore),
       _plain = plainFiles ?? PlainFiles(store: recordStore);

  final PersonStore personStore;
  final AssetRecordStore recordStore;

  /// The album tag for a code (`PasscodeTags.tagFor`).
  final Future<String> Function(String code) tagFor;
  final ManualAddService _manualAdd;
  final PlainFiles _plain;

  Future<PeopleZipResult> run(
    List<PeopleZipPick> picks, {
    String? code,
    void Function(int done, int total)? onProgress,
  }) async {
    final chosen = [
      for (final pick in picks)
        if (pick.include) pick,
    ];
    final written = await ProfileTransfer(store: personStore).write(
      [
        for (final pick in chosen)
          pick.person.profile ?? ProfileCsvRow(name: pick.person.name),
      ],
      targets: [for (final pick in chosen) pick.target],
    );
    final total = chosen.fold(0, (n, pick) => n + pick.photos.length);
    var done = 0, visible = 0, hidden = 0, failed = 0;
    onProgress?.call(done, total);
    for (final (i, pick) in chosen.indexed) {
      final personId = written.personIds[i];
      final hideCode = pick.hide && code != null
          ? await tagFor(personAlbumCode(personId, code))
          : null;
      final tagged = <String>[];
      for (final path in pick.person.photos.where(pick.photos.contains)) {
        try {
          if (hideCode != null) {
            final created = await _manualAdd.enqueueFile(
              path,
              passcodeHash: hideCode,
            );
            // Already here as an ordinary photo: left as it is.
            if (created.passcodeHash == hideCode) {
              await _plain.keep(created);
              hidden++;
            }
          } else {
            final created = await _manualAdd.enqueueFile(path);
            if (created.isVisibleInLibrary) {
              tagged.add(created.localId);
              visible++;
            }
          }
        } catch (_) {
          failed++;
        }
        onProgress?.call(++done, total);
      }
      if (tagged.isNotEmpty) {
        await recordStore.setArchived(tagged, true);
        await personStore.addAssets(personId, tagged);
      }
    }
    return PeopleZipResult(
      people: chosen.length,
      visible: visible,
      hidden: hidden,
      failed: failed,
    );
  }
}
