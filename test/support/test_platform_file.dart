import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';

/// A [PlatformFile] backed by a real file on disk, for faking the file
/// picker in tests without touching the real platform channel.
base class TestPlatformFile extends PlatformFile {
  TestPlatformFile(String filePath) : uri = Uri.file(filePath);

  @override
  final Uri uri;

  @override
  String get name => uri.pathSegments.last;

  @override
  XFile get xFile => XFile(path!);

  @override
  int? lengthSync() => null;

  @override
  Future<int> length() => File(path!).length();

  @override
  Future<Uint8List> readAsBytes() => File(path!).readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      File(path!).openRead().map(Uint8List.fromList);
}
