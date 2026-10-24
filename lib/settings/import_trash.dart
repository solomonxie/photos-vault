import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What the Files app's "delete" leaves in this app's Documents: moved to
/// `.Trash`, where it still takes its full space until emptied.
class ImportTrash {
  ImportTrash({Future<Directory> Function()? documents})
    : _documents = documents ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documents;

  Future<Directory> _dir() async =>
      Directory(p.join((await _documents()).path, '.Trash'));

  /// Bytes in it; 0 when there's none.
  Future<int> size() async {
    final dir = await _dir();
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// For good: these are files the user already deleted once.
  Future<void> empty() async {
    final dir = await _dir();
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      await entity.delete(recursive: true);
    }
  }
}
