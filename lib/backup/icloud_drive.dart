import 'dart:io';

import 'package:flutter/services.dart';

/// Why the iCloud container isn't usable — four unrelated causes that the
/// OS reports as one "nil container", and which need four different things
/// said about them.
///
/// Telling them apart is not fussiness. Every build signed by a free Apple
/// team is [notEntitled], and a build that reports that as "sign in to
/// iCloud" sends a user who is already signed in to go and sign in again.
enum ICloudState {
  /// Not iOS, or no platform channel (tests, a dev shell). The row doesn't
  /// belong on screen at all.
  unsupported,

  /// The build wasn't signed with the iCloud capability. Nothing the user
  /// can do about it, so nothing is asked of them.
  notEntitled,

  /// iCloud Drive is off for this account or this device — the one state
  /// with a fix the user can carry out, so the only one that gets
  /// directions.
  driveOff,

  /// The container exists but isn't ready yet (newly created, still
  /// propagating). Worth trying again shortly.
  notReady,

  /// Usable.
  available,
}

/// The app's own folder in iCloud Drive, over a platform channel.
///
/// Deliberately thin: check, write, read, list. What goes in the folder and
/// when is [ICloudBackup]'s business, which keeps all of that testable
/// without a device.
class ICloudDrive {
  ICloudDrive({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'byo.photos/icloud';

  final MethodChannel _channel;

  Future<ICloudState> status() async {
    if (!Platform.isIOS) return ICloudState.unsupported;
    try {
      final name = await _channel.invokeMethod<String>('status');
      return ICloudState.values.firstWhere(
        (state) => state.name == name,
        orElse: () => ICloudState.unsupported,
      );
    } on MissingPluginException {
      return ICloudState.unsupported;
    } catch (_) {
      return ICloudState.unsupported;
    }
  }

  /// Writes [contents] as [name] in the app's iCloud folder, replacing a
  /// file of the same name. Returns false if the write didn't happen.
  Future<bool> write(String name, String contents) async {
    try {
      return await _channel.invokeMethod<bool>('write', {
            'name': name,
            'contents': contents,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Writes [bytes] as [name], replacing a file of the same name — the
  /// zipped snapshot, which is not text and can't go through [write].
  Future<bool> writeBytes(String name, Uint8List bytes) async {
    try {
      return await _channel.invokeMethod<bool>('writeBytes', {
            'name': name,
            'bytes': bytes,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// The newest `.zip` in the folder, by name. `null` if there isn't one —
  /// including on an older backup, which is a single `.json` and comes back
  /// from [readLatest] instead.
  Future<Uint8List?> readLatestBytes() async {
    try {
      return await _channel.invokeMethod<Uint8List>('readLatestBytes');
    } catch (_) {
      return null;
    }
  }

  /// The most recent file in the folder, by name — which sorts by date
  /// because of how [ICloudBackup] names them. `null` if the folder is
  /// empty or unreadable.
  Future<String?> readLatest() async {
    try {
      return await _channel.invokeMethod<String>('readLatest');
    } catch (_) {
      return null;
    }
  }

  /// Every file in the folder, by name. What pruning needs: the folder is
  /// the only place that knows how many copies are really up there, and a
  /// device that has been off for a month can't work it out from its own
  /// records.
  Future<List<String>> list() async {
    try {
      final names = await _channel.invokeMethod<List<Object?>>('list');
      return (names ?? const []).whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// Removes one file by name. Only ever called on a name this app wrote —
  /// the folder is the user's, and anything else in it is theirs.
  Future<bool> delete(String name) async {
    try {
      return await _channel.invokeMethod<bool>('delete', {'name': name}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// When the newest file was written, for the row's subtitle.
  Future<DateTime?> latestWriteAt() async {
    try {
      final millis = await _channel.invokeMethod<int>('latestWriteAt');
      return millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis);
    } catch (_) {
      return null;
    }
  }
}
