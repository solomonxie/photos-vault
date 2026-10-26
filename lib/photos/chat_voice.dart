import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'conversation_file.dart';

/// Chat voice clips: one MP3 per message, `chats/voice/<hash>.mp3` under
/// Application Support, backed up as files (see `lib/backup/data_files.dart`).
///
/// An export is read before anybody says which people to import, so its
/// clips are first written to [staging] and only [adopt]ed into the folder
/// for messages actually imported.
class ChatVoice {
  ChatVoice({
    Future<Directory> Function()? support,
    Future<Directory> Function()? temp,
  }) : _support = support ?? getApplicationSupportDirectory,
       _temp = temp ?? getTemporaryDirectory;

  final Future<Directory> Function() _support;
  final Future<Directory> Function() _temp;

  static const folderName = 'chats/voice';

  static String fileNameOf(String hash) => '$hash.mp3';

  Future<Directory> folder() async =>
      Directory(p.joinAll([(await _support()).path, ...folderName.split('/')]));

  Future<Directory> staging() async =>
      Directory(p.join((await _temp()).path, 'chat_voice_staging'));

  Future<File> fileFor(String name) async =>
      File(p.join((await folder()).path, name));

  /// Moves the staged clips of [messages] in; a clip already there stays.
  /// The names now in the folder: only those may be written on a row.
  Future<Set<String>> adopt(Iterable<ConversationMessage> messages) async {
    final voiced = [
      for (final m in messages)
        if (m.voice != null) m.voice!,
    ];
    if (voiced.isEmpty) return const {};
    final from = (await staging()).path;
    final to = await folder();
    await to.create(recursive: true);
    final present = <String>{};
    for (final name in voiced) {
      final staged = File(p.join(from, name));
      final target = p.join(to.path, name);
      try {
        if (!await File(target).exists()) await staged.rename(target);
        present.add(name);
      } on FileSystemException {
        // Not staged (read elsewhere, or the staging was cleared): the
        // row gets no clip, and a later import can still bring it.
      }
    }
    return present;
  }
}

final chatVoice = ChatVoice();

/// One clip playing at a time, through `VoiceClipChannel.swift`.
class VoicePlayer {
  VoicePlayer._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'finished') playing.value = null;
    });
  }

  static final instance = VoicePlayer._();
  static const _channel = MethodChannel('byo.photos/voice_clip');

  /// The file name playing now, or null.
  final playing = ValueNotifier<String?>(null);

  /// Plays [name] (stopping anything else); its length, or null if it
  /// couldn't be played.
  Future<Duration?> play(String name) async {
    try {
      // Not imported yet (an import's preview): its staged copy.
      var file = await chatVoice.fileFor(name);
      if (!await file.exists()) {
        file = File(p.join((await chatVoice.staging()).path, name));
      }
      final seconds = await _channel.invokeMethod<double>('play', file.path);
      playing.value = name;
      return seconds == null
          ? null
          : Duration(milliseconds: (seconds * 1000).round());
    } on PlatformException {
      playing.value = null;
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> stop() async {
    playing.value = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No player (a test).
    }
  }
}
