import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Streaming SHA-256 of the file at [path] — used both to dedupe a fresh
/// manual add (`ManualAddService`) and to detect a tracked asset's local
/// file drifting since its last successful backup (`BackupCoordinator`).
///
/// In its own isolate: pure-Dart SHA over a photo is tens of milliseconds,
/// over a video seconds, and on the UI isolate that is dropped frames.
Future<String> hashFile(String path) => Isolate.run(() async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
});

/// Same digest, for bytes already in memory — how the bundled demo assets
/// are identified without writing them out first: their content hash is
/// their `manual:` local id, so the app can find (and remove) exactly what
/// it once seeded.
String hashBytes(Uint8List bytes) => sha256.convert(bytes).toString();

/// [hashBytes] off the calling isolate, for a buffer big enough to matter.
Future<String> hashBytesApart(Uint8List bytes) =>
    Isolate.run(() => hashBytes(bytes));
