import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_ops.dart';
import '../upload/pending_deletes.dart';
import '../upload/signing.dart';

/// Hidden photos a Mac encrypted and sent (`tools/hidden_upload/`), taken
/// on as this phone's own uploads so they aren't built and sent again.
///
/// The Mac drops `mac-uploads.jsonl` in Documents: one line per photo,
/// `{localId, file, hash}`, `file` a carrier name under `originals/`. A line
/// counts only once a live HEAD finds the object in every bucket; one this
/// phone has meanwhile sent itself leaves the Mac's copy to be deleted.
class MacUploads {
  MacUploads({
    required this.records,
    required this.targets,
    required this.documents,
    BucketOps? ops,
  }) : _ops = ops ?? BucketOps();

  static const fileName = 'mac-uploads.jsonl';

  final AssetRecordStore records;
  final BackupTargetsStore targets;
  final Future<Directory> Function() documents;
  final BucketOps _ops;

  /// How many photos were taken on. Read through, the file becomes
  /// `.done`; lines a bucket couldn't confirm yet are written back for the
  /// next run.
  Future<int> adopt() async {
    final file = File(p.join((await documents()).path, fileName));
    if (!await file.exists()) return 0;
    final all = await targets.loadAll();
    if (all.isEmpty) return 0;
    var adopted = 0;
    final orphans = <PendingDelete>[];
    final left = <String>[];
    Future<void> one(String line) async {
      if (line.trim().isEmpty) return;
      final Map<String, Object?> row;
      try {
        row = (jsonDecode(line) as Map).cast<String, Object?>();
      } catch (_) {
        return;
      }
      final id = row['localId'], name = row['file'], hash = row['hash'];
      if (id is! String || name is! String) return;
      final record = await records.getByLocalId(id);
      if (record == null || record.passcodeHash == null) return;
      final keys = {
        for (final t in all)
          t.id: derivativeKey(
            prefix: t.prefix,
            derivativeDir: 'originals',
            fileName: name,
          ),
      };
      if (record.stateOf(DerivativeKind.original).status ==
          UploadStatus.uploaded) {
        for (final t in all) {
          if (record.stateOf(DerivativeKind.original).destinationKey ==
              keys[t.id]) {
            continue;
          }
          orphans.add(
            PendingDelete(
              objectKey: keys[t.id]!,
              targetId: t.id,
              localId: id,
              carrier: true,
            ),
          );
        }
        return;
      }
      final heads = [for (final t in all) (t, await _ops.head(t, keys[t.id]!))];
      if (heads.any((h) => !h.$2.isPresent)) {
        left.add(line);
        return;
      }
      for (final (t, _) in heads) {
        await records.recordUpload(
          localId: id,
          kind: DerivativeKind.original,
          targetId: t.id,
          destinationKey: keys[t.id]!,
          sourceHash: hash is String ? hash : null,
        );
      }
      await records.updateDerivative(
        id,
        DerivativeKind.original,
        DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: keys[all.first.id],
          backedUpHash: hash is String ? hash : null,
        ),
      );
      adopted++;
    }

    // Sixteen HEADs in flight: one at a time, 15k photos kept the app
    // busy for an hour.
    final lines = await file.readAsLines();
    for (var i = 0; i < lines.length; i += 16) {
      await Future.wait(lines.skip(i).take(16).map(one));
    }
    if (orphans.isNotEmpty) {
      await PendingDeletes(store: records).add(orphans);
    }
    await file.rename('${file.path}.done');
    if (left.isNotEmpty) {
      await file.writeAsString('${left.join('\n')}\n');
    }
    return adopted;
  }
}
