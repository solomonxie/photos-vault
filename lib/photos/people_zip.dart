import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../storage/asset_record.dart';
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

  /// Unpacked folders an import never got to discard — the app killed
  /// mid-run, a run that failed. None is in use at launch. Returns bytes
  /// freed, best-effort.
  static Future<int> sweepLeftovers(Directory workDir) async {
    var freed = 0;
    try {
      await for (final entity in workDir.list(followLinks: false)) {
        if (entity is! Directory ||
            !p.basename(entity.path).startsWith('people-zip-')) {
          continue;
        }
        await for (final f in entity.list(
          recursive: true,
          followLinks: false,
        )) {
          if (f is File) freed += await f.length();
        }
        await entity.delete(recursive: true);
      }
    } catch (_) {}
    return freed;
  }

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

  /// A name typed over the zip's own, to merge into someone or be new.
  String? name;

  String get displayName => name ?? person.name;

  /// Who the profile goes to, once the user has said.
  PersonTarget? target;

  /// Who the photos go to: someone already in People. Null loads nothing.
  String? personId;
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

/// Two steps: [writeProfiles] for the people, then [run] for photos of
/// people who exist by then. Visible photos land in Archive, tagged to
/// their person; hidden ones are born hidden in the person's own folder
/// ([personAlbumCode]) and tagged to nobody, like every hidden photo.
/// Re-importing is a no-op per photo: ids come from content.
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

  /// The ticked rows that carry a profile; each written pick's [personId]
  /// is set to who it went to.
  /// Everyone ticked becomes, or merges into, a person: with their
  /// profile where the zip has one, by name alone where it only has photos.
  Future<ProfileImportResult> writeProfiles(List<PeopleZipPick> picks) async {
    final chosen = [
      for (final pick in picks)
        if (pick.include &&
            (pick.person.profile != null || pick.photos.isNotEmpty))
          pick,
    ];
    final written = await ProfileTransfer(store: personStore).write(
      [
        for (final pick in chosen)
          pick.person.profile?.withName(pick.displayName) ??
              ProfileCsvRow(name: pick.displayName),
      ],
      targets: [for (final pick in chosen) pick.target],
    );
    for (final (i, pick) in chosen.indexed) {
      pick.personId = written.personIds[i];
      pick.target = PersonTarget(pick.personId);
    }
    return written;
  }

  /// Photos of the ticked rows with a [PeopleZipPick.personId].
  Future<PeopleZipResult> run(
    List<PeopleZipPick> picks, {
    String? code,
    void Function(int done, int total)? onProgress,
  }) async {
    final chosen = [
      for (final pick in picks)
        if (pick.include && pick.personId != null && pick.photos.isNotEmpty)
          pick,
    ];
    // A photo with no camera date of its own takes its person's, rather
    // than the day it was imported: "last seen today" for somebody last
    // seen in 2009 is worse than a date to the nearest meeting.
    final spans = await personStore.openEventSpans();
    final total = chosen.fold(0, (n, pick) => n + pick.photos.length);
    var done = 0, visible = 0, hidden = 0, failed = 0;
    onProgress?.call(done, total);
    for (final pick in chosen) {
      final personId = pick.personId!;
      final span = spans[personId];
      final profile = pick.person.profile;
      final fallback =
          profile?.lastSeen ??
          span?.lastSeen ??
          profile?.firstMet ??
          span?.firstMet;
      final hideCode = pick.hide && code != null
          ? await tagFor(personAlbumCode(personId, code))
          : null;
      final tagged = <String>[];
      for (final path in pick.person.photos.where(pick.photos.contains)) {
        try {
          if (hideCode != null) {
            final created = await _dated(
              await _manualAdd.enqueueFile(
                path,
                passcodeHash: hideCode,
                fallbackDate: fallback,
              ),
              fallback,
            );
            // Already here as an ordinary photo: left as it is.
            if (created.passcodeHash == hideCode) {
              await _plain.keep(created);
              hidden++;
            }
          } else {
            // Archived and kept for its person as it is written, so it
            // reaches neither the grid nor Archive. A photo already here
            // keeps whatever it was.
            final created = await _dated(
              await _manualAdd.enqueueFile(
                path,
                isArchived: true,
                peopleOnly: true,
                fallbackDate: fallback,
              ),
              fallback,
            );
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
        await personStore.addAssets(personId, tagged);
        // Loaded before this flag existed: still archived ones become
        // their person's only. One moved to the library stays there.
        await recordStore.setPeopleOnly(tagged, true);
      }
    }
    return PeopleZipResult(
      people: chosen.length,
      visible: visible,
      hidden: hidden,
      failed: failed,
    );
  }

  /// One imported before undated photos took their person's date: dated
  /// now, by [fallback]. A photo that was given a date keeps it.
  Future<AssetRecord> _dated(AssetRecord record, DateTime? fallback) async {
    if (fallback == null || !undatedImport(record)) return record;
    await recordStore.setCreatedAt(record.localId, fallback);
    return record;
  }
}

/// Dated only by the moment it was added: a file with no camera date of
/// its own. A camera-roll photo always has Photos' date.
bool undatedImport(AssetRecord record) =>
    record.sourceType != AssetSourceType.photoManager &&
    record.createdAt == record.addedAt;
