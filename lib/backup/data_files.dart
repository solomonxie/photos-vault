import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../photos/ai_analysis_store.dart';
import '../photos/conversation_store.dart';
import '../photos/chat_voice.dart';
import '../photos/words_store.dart';

/// Everything the app holds that isn't rows in `library.json`: the chat
/// history, the writings and their pictures, the faces. Too big to rebuild
/// into one zip every day (the chats alone are a hundred megabytes), so
/// each goes up as its own file, named by the SHA-256 of its bytes — a
/// **blob** — and the day's zip carries only the list of which blobs make
/// up that day (`data-files.json`). Unchanged data has the same name
/// tomorrow and is never sent twice.
///
/// | Store | Blob |
/// |---|---|
/// | `conversations.db` | gzip of a `VACUUM INTO` copy |
/// | `words.db` | gzip of a `VACUUM INTO` copy |
/// | `ai_analysis.db` | gzip of a copy without hidden photos' faces |
/// | `words/media/…` | each picture as it is |
/// | `chats/voice/…` | each voice clip as it is |
///
/// Not here, on purpose: `photos_vault.db`, `people.db`, `photo_albums.db`
/// (their rows are `library.json`), and `sync_jobs.db` — the upload queue,
/// rebuilt from the records on the next launch; restoring it would replay
/// uploads of photos that may be gone.
///
/// Restoring merges (`INSERT OR IGNORE` over shared columns), never
/// replaces: see `mergeDatabase`.
class DataFileEntry {
  const DataFileEntry({
    required this.name,
    required this.kind,
    required this.sha256,
    required this.bytes,
    this.gzip = false,
  });

  /// `conversations.db`, or a file's path under Application Support
  /// (`words/media/<id>/1.jpg`).
  final String name;

  /// `db` or `file`.
  final String kind;
  final String sha256;

  /// Size of the blob as stored.
  final int bytes;
  final bool gzip;

  Map<String, Object?> toJson() => {
    'name': name,
    'kind': kind,
    'sha256': sha256,
    'bytes': bytes,
    if (gzip) 'gzip': true,
  };

  static DataFileEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final sha = json['sha256'];
    final kind = json['kind'];
    if (name is! String || sha is! String || kind is! String) return null;
    if (!isBlobName(sha)) return null;
    return DataFileEntry(
      name: name,
      kind: kind,
      sha256: sha,
      bytes: json['bytes'] is int ? json['bytes'] as int : 0,
      gzip: json['gzip'] == true,
    );
  }

  static List<DataFileEntry> listFrom(Iterable<Object?> json) => [
    for (final j in json) ?fromJson(j),
  ];
}

/// A blob's name: 64 lowercase hex digits, nothing else. What every
/// destination checks before reading, writing or deleting one.
bool isBlobName(String name) => RegExp(r'^[0-9a-f]{64}$').hasMatch(name);

/// The day's blobs on this phone: each entry and the local file holding its
/// bytes. Database copies are temporary; [dispose] removes them.
class DataFileSet {
  DataFileSet(this.entries, this.files, this._staging);

  final List<DataFileEntry> entries;

  /// sha256 → local file with exactly those bytes.
  final Map<String, String> files;
  final Directory? _staging;

  int get totalBytes => entries.fold(0, (n, e) => n + e.bytes);

  List<Map<String, Object?>> get manifest => [
    for (final e in entries) e.toJson(),
  ];

  Future<void> dispose() async {
    try {
      await _staging?.delete(recursive: true);
    } catch (_) {}
  }
}

/// Fetches the blob [sha256] into [toPath]; false when no copy answered.
typedef BlobFetch = Future<bool> Function(String sha256, String toPath);

class DataFiles {
  DataFiles({
    this.conversations,
    this.words,
    this.analysis,
    Future<Directory> Function()? supportDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final ConversationStore? conversations;
  final WordsStore? words;
  final AiAnalysisStore? analysis;

  /// Where `words/media` and `chats/voice` live. Overridable so a test never asks iOS.
  final Future<Directory> Function() _supportDirectory;

  static const conversationsName = 'conversations.db';
  static const wordsName = 'words.db';
  static const analysisName = 'ai_analysis.db';
  static const mediaFolder = 'words/media';
  static const voiceFolder = ChatVoice.folderName;

  /// Moves whenever any of the three stores is written. Best-effort per
  /// store: one that can't be opened (never used) counts as zero.
  Future<int> mark() async {
    var mark = 0;
    for (final read in [
      () => conversations?.dataMark(),
      () => words?.dataMark(),
      () => analysis?.dataMark(),
    ]) {
      try {
        mark += await read() ?? 0;
      } catch (_) {}
    }
    return mark;
  }

  /// Copies, compresses and fingerprints everything, off the UI isolate.
  /// Throws if any of it can't be: a list missing a store would restore as
  /// that store being empty, so a short list is never handed out.
  Future<DataFileSet> collect({Set<String> hiddenIds = const {}}) async {
    final staging = await Directory.systemTemp.createTemp('pv_data_');
    final entries = <DataFileEntry>[];
    final files = <String, String>{};

    Future<void> db(
      String name,
      Future<bool> Function(String dest) copy,
    ) async {
      final raw = p.join(staging.path, name);
      if (!await copy(raw)) throw StateError('could not copy $name');
      final gz = '$raw.gz';
      final (sha, size) = await Isolate.run(() => _gzipAndHash(raw, gz));
      await File(raw).delete();
      entries.add(
        DataFileEntry(
          name: name,
          kind: 'db',
          sha256: sha,
          bytes: size,
          gzip: true,
        ),
      );
      files[sha] = gz;
    }

    try {
      if (conversations case final c?) await db(conversationsName, c.copyTo);
      if (words case final w?) await db(wordsName, w.copyTo);
      if (analysis case final a?) {
        await db(analysisName, (dest) => a.copyTo(dest, hiddenIds));
      }
      final folders = [
        if (words != null) mediaFolder,
        if (conversations != null) voiceFolder,
      ];
      final support = folders.isEmpty ? '' : (await _supportDirectory()).path;
      for (final folder in folders) {
        final dir = Directory(p.joinAll([support, ...p.posix.split(folder)]));
        if (!await dir.exists()) continue;
        final paths = [
          await for (final f in dir.list(recursive: true))
            if (f is File) f.path,
        ];
        final hashed = await Isolate.run(() => _hashAll(paths));
        for (final (path, sha, size) in hashed) {
          entries.add(
            DataFileEntry(
              name: p.posix.joinAll(p.split(p.relative(path, from: support))),
              kind: 'file',
              sha256: sha,
              bytes: size,
            ),
          );
          files[sha] = path;
        }
      }
    } catch (_) {
      await staging.delete(recursive: true);
      rethrow;
    }
    return DataFileSet(entries, files, staging);
  }

  /// Puts back what [entries] list, fetching each blob through [fetch].
  /// Each is checked against its SHA-256 before use; one that fails is
  /// skipped and the rest still restore. Returns how many came back.
  Future<int> restore(List<DataFileEntry> entries, BlobFetch fetch) async {
    if (entries.isEmpty) return 0;
    final scratch = await Directory.systemTemp.createTemp('pv_restore_');
    final support = (await _supportDirectory()).path;
    var restored = 0;
    try {
      for (final entry in entries) {
        try {
          if (await _restoreOne(entry, fetch, scratch.path, support)) {
            restored++;
          }
        } catch (_) {
          // This one's lost; the others still come back.
        }
      }
    } finally {
      try {
        await scratch.delete(recursive: true);
      } catch (_) {}
    }
    return restored;
  }

  Future<bool> _restoreOne(
    DataFileEntry entry,
    BlobFetch fetch,
    String scratch,
    String support,
  ) async {
    if (entry.kind == 'file') {
      final target = _fileTarget(entry.name, support);
      if (target == null) return false;
      if (await File(target).exists()) return true;
    }
    final blob = p.join(scratch, entry.sha256);
    if (!await fetch(entry.sha256, blob)) return false;
    final sha = await Isolate.run(() => _hashFile(blob));
    if (sha != entry.sha256) return false;
    if (entry.kind == 'file') {
      final target = _fileTarget(entry.name, support)!;
      await Directory(p.dirname(target)).create(recursive: true);
      await File(blob).copy(target);
      return true;
    }
    final db = p.join(scratch, '${entry.sha256}.db');
    if (entry.gzip) {
      await Isolate.run(() => _gunzip(blob, db));
    } else {
      await File(blob).rename(db);
    }
    final merge = switch (entry.name) {
      conversationsName => conversations?.mergeFrom,
      wordsName => words?.mergeFrom,
      analysisName => analysis?.mergeFrom,
      _ => null,
    };
    if (merge == null) return false;
    await merge(db);
    return true;
  }

  /// Only under `words/media/` or `chats/voice/`, and never outside them.
  static String? _fileTarget(String name, String support) {
    final inside =
        name.startsWith('$mediaFolder/') || name.startsWith('$voiceFolder/');
    if (!inside || name.contains('..')) return null;
    return p.joinAll([support, ...p.posix.split(name)]);
  }
}

Future<(String, int)> _gzipAndHash(String from, String to) async {
  await File(from)
      .openRead()
      .transform(gzip.encoder)
      .pipe(File(to).openWrite());
  return (await _hashFile(to), await File(to).length());
}

Future<String> _hashFile(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

Future<List<(String, String, int)>> _hashAll(List<String> paths) async => [
  for (final path in paths)
    (path, await _hashFile(path), await File(path).length()),
];

Future<void> _gunzip(String from, String to) =>
    File(from).openRead().transform(gzip.decoder).pipe(File(to).openWrite());

/// The manifest as the zip carries it.
String encodeDataFiles(List<Map<String, Object?>> manifest) =>
    jsonEncode({'version': 1, 'files': manifest});

List<DataFileEntry> decodeDataFiles(String json) {
  try {
    final root = jsonDecode(json);
    final files = root is Map ? root['files'] : null;
    return files is List ? DataFileEntry.listFrom(files) : const [];
  } catch (_) {
    return const [];
  }
}
