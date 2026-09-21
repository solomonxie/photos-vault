import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../photos/image_pipeline.dart';
import '../storage/asset_record.dart';
import 'carrier.dart';
import 'cipher.dart';
import 'decoy.dart';
import 'keys.dart';
import 'still_video.dart';

/// Turns a hidden photo into the one object it becomes: somebody else's
/// picture, carrying this one inside it.
///
/// Everything that touches a decoder runs on an isolate — a 12 MP upscale
/// on the UI isolate is a freeze, and this is called from the sync queue
/// while the grid is being scrolled.
class CarrierBuilder {
  CarrierBuilder({
    VaultCipher? cipher,
    StillVideo? stillVideo,
    Future<Directory> Function()? temporaryDirectory,
    Future<Uint8List?> Function(AssetRecord record)? posterFrame,
    Future<Duration?> Function(AssetRecord record)? videoDuration,
    Random? random,
  }) : _cipher = cipher ?? PlatformCipher(),
       _stillVideo = stillVideo ?? const StillVideo(),
       _temporaryDirectory = temporaryDirectory ?? Directory.systemTemp.create,
       _posterFrame = posterFrame ?? ((_) async => null),
       _videoDuration = videoDuration ?? ((_) async => null),
       _random = random ?? Random.secure();

  final VaultCipher _cipher;
  final StillVideo _stillVideo;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<Uint8List?> Function(AssetRecord record) _posterFrame;
  final Future<Duration?> Function(AssetRecord record) _videoDuration;
  final Random _random;

  /// How many decoys each picture has already worn. Kept in memory only —
  /// a table of which object wears which face would be a list of exactly
  /// which objects are carriers, in the database, riding to the bucket in
  /// the snapshot.
  final Map<String, int> _decoyUses = {};

  /// The carrier for [record], written to a temp file the caller owns, or
  /// null when there is no decoy to wear — in which case the upload is
  /// refused rather than sent as something conspicuous.
  Future<File?> build({
    required AssetRecord record,
    required String filePath,
    required AlbumKeys keys,
    required List<DecoyCandidate> candidates,
  }) async {
    final original = await File(filePath).readAsBytes();
    final thumbnail = await _thumbnailFor(record, original);
    if (thumbnail == null) return null;

    final chosen = chooseDecoy(
      candidates: [for (final c in candidates) c.source],
      payloadBytes: original.length,
      wantVideo: record.countsAsVideo,
      usedCounts: _decoyUses,
      random: _random,
    );
    if (chosen == null) return null;
    final candidate = candidates.firstWhere((c) => c.source.id == chosen.id);
    final decoyThumbnail = await candidate.thumbnail();
    if (decoyThumbnail == null) return null;

    final dir = await _temporaryDirectory();
    final extension = p.extension(filePath).replaceFirst('.', '').toLowerCase();

    final carrier = record.countsAsVideo
        ? await _videoCarrier(
            keys: keys,
            candidate: candidate,
            decoyThumbnail: decoyThumbnail,
            thumbnail: thumbnail,
            original: original,
            extension: extension,
            directory: dir,
          )
        : await _photoCarrier(
            keys: keys,
            candidate: candidate,
            decoyThumbnail: decoyThumbnail,
            thumbnail: thumbnail,
            original: original,
            extension: extension,
            directory: dir,
          );
    if (carrier == null) return null;
    _decoyUses[chosen.id] = (_decoyUses[chosen.id] ?? 0) + 1;
    return carrier;
  }

  Future<File?> _photoCarrier({
    required AlbumKeys keys,
    required DecoyCandidate candidate,
    required Uint8List decoyThumbnail,
    required Uint8List thumbnail,
    required Uint8List original,
    required String extension,
    required Directory directory,
  }) async {
    final source = candidate.source;
    final decoy = await Isolate.run(
      () => buildDecoyJpeg(
        thumbnail: decoyThumbnail,
        width: source.width,
        height: source.height,
        takenAt: source.takenAt,
      ),
    );
    if (decoy == null) return null;
    final bytes = buildJpegCarrier(
      cipher: _cipher,
      keys: keys.carrier,
      masterSalt: keys.entry.salt,
      decoy: decoy,
      thumbnail: thumbnail,
      original: original,
      extension: extension,
    );
    if (bytes == null) return null;
    final file = File(p.join(directory.path, 'carrier.jpg'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// The decoy runs for the decoy's own duration, which is what makes the
  /// object plausible: 200 MB over three minutes is an ordinary capture,
  /// the same bytes over two seconds is 800 Mbps and nothing on earth.
  Future<File?> _videoCarrier({
    required AlbumKeys keys,
    required DecoyCandidate candidate,
    required Uint8List decoyThumbnail,
    required Uint8List thumbnail,
    required Uint8List original,
    required String extension,
    required Directory directory,
  }) async {
    final duration = candidate.duration;
    if (duration == null || duration <= Duration.zero) return null;
    final decoyPath = p.join(directory.path, 'decoy.mov');
    final decoyFile = await _stillVideo.render(
      still: decoyThumbnail,
      width: candidate.source.width,
      height: candidate.source.height,
      duration: duration,
      path: decoyPath,
    );
    if (decoyFile == null) return null;
    final bytes = buildMp4Carrier(
      cipher: _cipher,
      keys: keys.carrier,
      masterSalt: keys.entry.salt,
      decoy: await decoyFile.readAsBytes(),
      poster: thumbnail,
      original: original,
      extension: extension,
    );
    await decoyFile.delete();
    if (bytes == null) return null;
    final file = File(p.join(directory.path, 'carrier.mov'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// The hidden photo's own thumbnail, made here and never written to disk
  /// in the clear — it goes straight into the carrier, encrypted.
  Future<Uint8List?> _thumbnailFor(
    AssetRecord record,
    Uint8List original,
  ) async {
    if (record.countsAsVideo) return _posterFrame(record);
    return Isolate.run(() => encodeThumbnail(original));
  }

  Future<Duration?> durationOf(AssetRecord record) => _videoDuration(record);
}

/// A photo the carrier could pretend to be, with its thumbnail fetched
/// lazily — the pool is the whole ordinary library, and reading every
/// candidate's thumbnail to choose one would be absurd.
class DecoyCandidate {
  const DecoyCandidate({
    required this.source,
    required this.thumbnail,
    this.duration,
  });

  final DecoySource source;
  final Future<Uint8List?> Function() thumbnail;

  /// Videos only, and required for them: the decoy runs this long.
  final Duration? duration;
}
