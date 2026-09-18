import 'dart:io';

import 'package:bring_your_own_photos/backup/app_snapshot.dart';
import 'package:bring_your_own_photos/backup/backup_schedule.dart';
import 'package:bring_your_own_photos/backup/local_vault.dart';
import 'package:bring_your_own_photos/storage/asset_record_store.dart';

/// A vault that records what it was asked to do and touches no disk.
///
/// Widget tests run in `testWidgets`' fake-async zone, where a real
/// `path_provider` call is a platform-channel round trip that never
/// resolves — so a screen that takes a safety copy before a big operation
/// would hang on the copy and never get to the operation. [guards] is what
/// a test asserts on instead: that the copy was asked for, and before what.
class FakeLocalVault implements LocalVault {
  final guards = <String>[];
  var dailyCopies = 0;

  @override
  Future<File?> guard(String operation) async {
    guards.add(operation);
    return null;
  }

  @override
  Future<bool> keepDailyCopy() async {
    dailyCopies++;
    return true;
  }

  @override
  Future<bool> copyNow() async => keepDailyCopy();

  @override
  Future<void> prune() async {}

  @override
  Future<List<File>> localCopies() async => const [];

  @override
  BackupSchedule get schedule => throw UnimplementedError();

  @override
  AppSnapshotIo get snapshots => throw UnimplementedError();

  @override
  AssetRecordStore get settings => throw UnimplementedError();
}
