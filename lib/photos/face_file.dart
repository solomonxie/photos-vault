import 'dart:convert';
import 'dart:isolate';

import 'person.dart' show FaceRect;

/// One face in a [FaceFile]: a box on the upright picture, 0..1 from the
/// top-left, and who it is — or, from v2, only which [group] it is in.
class FaceFileFace {
  const FaceFileFace(this.box, String this.person) : group = null;

  const FaceFileFace.grouped(this.box, String this.group) : person = null;

  final FaceRect box;
  final String? person;
  final String? group;
}

/// A v2 group of unnamed faces: [suggest] is a proposal, never a name.
class FaceFileGroup {
  const FaceFileGroup(this.id, {this.suggest});

  final String id;
  final String? suggest;
}

/// One photo in a [FaceFile], by bucket key stem or the original's SHA-256.
class FaceFilePhoto {
  const FaceFilePhoto({this.key, this.sha256, required this.faces});

  final String? key;
  final String? sha256;
  final List<FaceFileFace> faces;
}

/// `faces.json` v1 or v2 — see `docs/design/face-recognition/DESIGN.md`.
/// Read tolerantly: unknown fields are ignored, a photo or face that can't
/// be read is dropped and counted in [unreadable].
class FaceFile {
  const FaceFile({
    required this.photos,
    this.groups = const {},
    this.unreadable = 0,
  });

  final List<FaceFilePhoto> photos;

  /// Every group a face is in, by id. Empty in v1.
  final Map<String, FaceFileGroup> groups;
  final int unreadable;

  int get faceCount => photos.fold(0, (n, p) => n + p.faces.length);

  /// Throws [FormatException] for anything that isn't a v1 or v2 face
  /// file.
  static FaceFile parse(String text) {
    final root = jsonDecode(text);
    final version = root is Map ? root['version'] : null;
    if (root is! Map ||
        (version != 1 && version != 2) ||
        root['photos'] is! List) {
      throw const FormatException('Not a faces.json version 1 or 2 file');
    }
    final grouped = version == 2;
    final declared = <String, FaceFileGroup>{};
    if (root['groups'] case final List list when grouped) {
      for (final g in list) {
        if (g is! Map) continue;
        if (_text(g['id']) case final id?) {
          declared[id] = FaceFileGroup(id, suggest: _text(g['suggest']));
        }
      }
    }
    final groups = <String, FaceFileGroup>{};
    final photos = <FaceFilePhoto>[];
    var unreadable = 0;
    for (final entry in root['photos'] as List) {
      if (entry is! Map) {
        unreadable++;
        continue;
      }
      final key = _text(entry['key']);
      final sha = _text(entry['sha256'])?.toLowerCase();
      final faces = <FaceFileFace>[];
      if (entry['faces'] case final List list) {
        for (final f in list) {
          final face = f is Map ? _face(f, grouped) : null;
          face == null ? unreadable++ : faces.add(face);
        }
      }
      if (key == null && sha == null) {
        unreadable += faces.isEmpty ? 1 : faces.length;
        continue;
      }
      if (faces.isNotEmpty) {
        photos.add(FaceFilePhoto(key: key, sha256: sha, faces: faces));
        for (final f in faces) {
          if (f.group case final id?) {
            groups[id] ??= declared[id] ?? FaceFileGroup(id);
          }
        }
      }
    }
    return FaceFile(photos: photos, groups: groups, unreadable: unreadable);
  }

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  /// A person or, in v2, a group: never both, never neither.
  static FaceFileFace? _face(Map face, bool grouped) {
    final person = _text(face['person']);
    final group = grouped ? _text(face['group']) : null;
    if ((person == null) == (group == null)) return null;
    final box = _box(face['box']);
    if (box == null) return null;
    return person != null
        ? FaceFileFace(box, person)
        : FaceFileFace.grouped(box, group!);
  }

  static FaceRect? _box(Object? box) {
    if (box is! List || box.length != 4) return null;
    if (box.any((n) => n is! num || !n.isFinite)) return null;
    final [x, y, w, h] = [for (final n in box) (n as num).toDouble()];
    if (x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= 1 && y + h <= 1) {
      return FaceRect(x, y, w, h);
    }
    final left = x.clamp(0.0, 1.0);
    final top = y.clamp(0.0, 1.0);
    final right = (x + w).clamp(0.0, 1.0);
    final bottom = (y + h).clamp(0.0, 1.0);
    if (right <= left || bottom <= top) return null;
    return FaceRect(left, top, right - left, bottom - top);
  }
}

/// [FaceFile.parse] off the UI isolate: the file can be a few megabytes.
Future<FaceFile> readFaceFile(List<int> bytes) =>
    Isolate.run(() => FaceFile.parse(utf8.decode(bytes)));
