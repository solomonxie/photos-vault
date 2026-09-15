import 'dart:io';

import 'package:crypto/crypto.dart';

/// Streaming SHA-256 of the file at [path] — used both to dedupe a fresh
/// manual add (`ManualAddService`) and to detect a tracked asset's local
/// file drifting since its last successful backup (`BackupCoordinator`).
Future<String> hashFile(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}
