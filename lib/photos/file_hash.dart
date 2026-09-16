import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Streaming SHA-256 of the file at [path] — used both to dedupe a fresh
/// manual add (`ManualAddService`) and to detect a tracked asset's local
/// file drifting since its last successful backup (`BackupCoordinator`).
Future<String> hashFile(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}

/// Same digest, for bytes already in memory — how the bundled demo assets
/// are identified without writing them out first: their content hash is
/// their `manual:` local id, so the app can find (and remove) exactly what
/// it once seeded.
String hashBytes(Uint8List bytes) => sha256.convert(bytes).toString();
