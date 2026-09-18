import 'dart:io';

import 'package:bring_your_own_photos/backup/app_snapshot.dart';
import 'package:bring_your_own_photos/backup/local_vault.dart';
import 'package:bring_your_own_photos/backup/snapshot_file.dart';

/// Export and import with no disk and no picker.
///
/// Widget tests run in `testWidgets`' fake-async zone, where a real file
/// read never resolves — so a screen that picks a file and reads it would
/// hang before it ever showed the confirmation the test is about. Reading
/// a real zip off disk is covered by `snapshot_file_test.dart`, in a plain
/// `test()`.
class FakeSnapshotFile implements SnapshotFile {
  FakeSnapshotFile({required this.vault, this.picked, this.exported});

  @override
  final LocalVault vault;

  /// What the picker hands back. `null` stands for both a cancelled pick
  /// and a file that isn't one of ours — which the screen treats alike.
  final AppSnapshot? picked;

  final File? exported;

  final restored = <AppSnapshot>[];

  @override
  Future<AppSnapshot?> pick() async => picked;

  @override
  Future<AppSnapshot?> read(File file) async => picked;

  @override
  Future<File?> export() async => exported;

  @override
  Future<int> restore(AppSnapshot snapshot) async {
    await vault.guard('restore');
    restored.add(snapshot);
    return snapshot.assets.length;
  }

  @override
  AppSnapshotIo get snapshots => throw UnimplementedError();
}
