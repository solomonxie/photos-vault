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
import 'object_key.dart';
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
  ///
  /// [motionOf] is set for a Live Photo's `.mov` half — the path of its
  /// still, which gives the poster. It goes up as a video carrier, so it is
  /// named `.mov` beside the still's `.jpg` rather than over it.
  Future<File?> build({
    required AssetRecord record,
    required String filePath,
    required AlbumKeys keys,
    required List<DecoyCandidate> candidates,
    String? motionOf,
  }) async {
    // The original is read inside the isolates that need it, never here: a
    // video held on the UI heap, twice over while it is encrypted, is what
    // iOS kills the app for.
    final payloadBytes = await File(filePath).length();
    final asVideo = record.countsAsVideo || motionOf != null;
    final thumbnail = motionOf != null
        ? await _stillThumbnail(motionOf)
        : await _thumbnailFor(record, filePath);
    if (thumbnail == null) return null;

    final chosen = chooseDecoy(
      candidates: [for (final c in candidates) c.source],
      payloadBytes: payloadBytes,
      wantVideo: asVideo,
      usedCounts: _decoyUses,
      random: _random,
    );
    if (chosen == null) return null;
    final candidate = candidates.firstWhere((c) => c.source.id == chosen.id);
    final decoyThumbnail = await candidate.thumbnail();
    if (decoyThumbnail == null) return null;

    final dir = await _temporaryDirectory();
    final extension = p.extension(filePath).replaceFirst('.', '').toLowerCase();
    final nonce = hiddenNonce(keys.carrier, record);
    final meta = CarrierMeta(
      takenAt: record.createdAt,
      width: record.width ?? 0,
      height: record.height ?? 0,
      isVideo: record.countsAsVideo,
    );
    final baseName = hiddenBaseName(keys.carrier, record);

    final carrier = asVideo
        ? await _videoCarrier(
            keys: keys,
            candidate: candidate,
            decoyThumbnail: decoyThumbnail,
            thumbnail: thumbnail,
            originalPath: filePath,
            extension: extension,
            directory: dir,
            nonce: nonce,
            meta: meta,
            baseName: baseName,
          )
        : await _photoCarrier(
            keys: keys,
            candidate: candidate,
            decoyThumbnail: decoyThumbnail,
            thumbnail: thumbnail,
            originalPath: filePath,
            extension: extension,
            directory: dir,
            nonce: nonce,
            meta: meta,
            baseName: baseName,
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
    required String originalPath,
    required String extension,
    required Directory directory,
    required Uint8List nonce,
    required CarrierMeta meta,
    required String baseName,
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
    final cipher = _cipher;
    final carrierKeys = keys.carrier;
    final salt = keys.entry.salt;
    final out = p.join(directory.path, '$baseName.jpg');
    final wrote = await Isolate.run(() async {
      final bytes = buildJpegCarrier(
        cipher: cipher,
        keys: carrierKeys,
        masterSalt: salt,
        decoy: decoy,
        thumbnail: thumbnail,
        original: await File(originalPath).readAsBytes(),
        extension: extension,
        nonce: nonce,
        meta: meta,
      );
      if (bytes == null) return false;
      await File(out).writeAsBytes(bytes, flush: true);
      return true;
    });
    return wrote ? File(out) : null;
  }

  /// The decoy runs for the decoy's own duration, which is what makes the
  /// object plausible: 200 MB over three minutes is an ordinary capture,
  /// the same bytes over two seconds is 800 Mbps and nothing on earth.
  Future<File?> _videoCarrier({
    required AlbumKeys keys,
    required DecoyCandidate candidate,
    required Uint8List decoyThumbnail,
    required Uint8List thumbnail,
    required String originalPath,
    required String extension,
    required Directory directory,
    required Uint8List nonce,
    required CarrierMeta meta,
    required String baseName,
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
    final cipher = _cipher;
    final carrierKeys = keys.carrier;
    final salt = keys.entry.salt;
    final decoyFilePath = decoyFile.path;
    final out = p.join(directory.path, '$baseName.mov');
    // Still whole-file in memory, inside the isolate: original, its
    // ciphertext and the carrier — about 3x the video. Bounded by the
    // largest hidden video until the carrier is written as a stream.
    final wrote = await Isolate.run(() async {
      final bytes = buildMp4Carrier(
        cipher: cipher,
        keys: carrierKeys,
        masterSalt: salt,
        decoy: await File(decoyFilePath).readAsBytes(),
        poster: thumbnail,
        original: await File(originalPath).readAsBytes(),
        extension: extension,
        nonce: nonce,
        meta: meta,
      );
      if (bytes == null) return false;
      await File(out).writeAsBytes(bytes, flush: true);
      return true;
    });
    await decoyFile.delete();
    return wrote ? File(out) : null;
  }

  /// The hidden photo's own thumbnail, made here and never written to disk
  /// in the clear — it goes straight into the carrier, encrypted.
  Future<Uint8List?> _thumbnailFor(AssetRecord record, String path) async {
    if (record.countsAsVideo) {
      final poster = await _posterFrame(record);
      if (poster == null || poster.length <= carrierThumbnailBudget) {
        return poster;
      }
      return Isolate.run(
        () => encodeThumbnail(poster, maxBytes: carrierThumbnailBudget),
      );
    }
    return Isolate.run(
      () async => encodeThumbnail(
        await File(path).readAsBytes(),
        maxBytes: carrierThumbnailBudget,
      ),
    );
  }

  Future<Uint8List?> _stillThumbnail(String stillPath) async {
    try {
      final still = await File(stillPath).readAsBytes();
      return await Isolate.run(
        () => encodeThumbnail(still, maxBytes: carrierThumbnailBudget),
      );
    } catch (_) {
      return null;
    }
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
