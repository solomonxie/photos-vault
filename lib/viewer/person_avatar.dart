import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';

import '../photos/person.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'face_crop_disk.dart';

/// A person's profile picture — resolved on demand from their
/// `avatarLocalId` (one of their own tagged photos, not a separate upload),
/// cropped to [face] when the photo is a group shot and only part of it is
/// them. Falls back to [fallbackLocalId], then a plain person glyph, when
/// the photo is gone or not visible outside the private gate.
/// The avatar that flies between a person's page and their profile.
String personAvatarHeroTag(String personId) => 'person-avatar:$personId';

class PersonAvatar extends StatefulWidget {
  const PersonAvatar({
    super.key,
    required this.assetRecordStore,
    required this.localId,
    this.face,
    this.fallbackLocalId,
    this.records,
    this.size = 64,
  });

  /// Their chosen picture, or — until one's been chosen, or while it can't
  /// be shown — the first photo they're tagged in: somebody with photos
  /// should never sit behind a grey glyph. A face box only means anything
  /// on the photo it was tapped in, so it's dropped along with the photo.
  factory PersonAvatar.forPerson({
    required AssetRecordStore assetRecordStore,
    required Person person,
    String? firstTaggedLocalId,
    Map<String, AssetRecord>? records,
    double size = 64,
  }) => PersonAvatar(
    assetRecordStore: assetRecordStore,
    localId: person.avatarLocalId ?? firstTaggedLocalId,
    face: person.avatarLocalId == null ? null : person.avatarFace,
    fallbackLocalId: person.avatarLocalId == null ? null : firstTaggedLocalId,
    records: records,
    size: size,
  );

  final AssetRecordStore assetRecordStore;
  final String? localId;

  /// Which part of the photo is this person — see [Person.avatarFace].
  /// Null shows the whole photo, centre-cropped to the circle.
  final FaceRect? face;

  /// Drawn whole when [localId] can't be shown.
  final String? fallbackLocalId;

  /// The visible library by id ([visibleRecordsOf]). Given, the avatar
  /// resolves from it with no query: a list of avatars is one read, not
  /// one per avatar mounted (UI-10).
  final Map<String, AssetRecord>? records;
  final double size;

  @override
  State<PersonAvatar> createState() => _PersonAvatarState();
}

class _PersonAvatarState extends State<PersonAvatar> {
  /// Read once per photo, not per build: a list `setState` rebuilds every
  /// visible avatar.
  late Future<(AssetRecord, FaceRect?)?> _resolved = _resolve();

  @override
  void didUpdateWidget(PersonAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.records == null &&
        (oldWidget.records != null ||
            oldWidget.localId != widget.localId ||
            oldWidget.face != widget.face ||
            oldWidget.fallbackLocalId != widget.fallbackLocalId ||
            oldWidget.assetRecordStore != widget.assetRecordStore)) {
      _resolved = _resolve();
    }
  }

  Future<(AssetRecord, FaceRect?)?> _resolve() async {
    final id = widget.localId;
    final fallback = widget.fallbackLocalId;
    final ids = [?id, ?fallback];
    if (ids.isEmpty) return null;
    final visible = await widget.assetRecordStore.getVisibleByLocalIds(ids);
    if (visible[id] case final record?) return (record, widget.face);
    if (visible[fallback] case final record?) return (record, null);
    return null;
  }

  (AssetRecord, FaceRect?)? _fromMemory(Map<String, AssetRecord> records) {
    if (records[widget.localId] case final record?) {
      return (record, widget.face);
    }
    if (records[widget.fallbackLocalId] case final record?) {
      return (record, null);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final records = widget.records;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: records != null
            ? _picture(context, _fromMemory(records))
            : FutureBuilder<(AssetRecord, FaceRect?)?>(
                future: _resolved,
                builder: (context, snapshot) =>
                    _picture(context, snapshot.data),
              ),
      ),
    );
  }

  Widget _picture(BuildContext context, (AssetRecord, FaceRect?)? resolved) {
    if (resolved == null) return _placeholder();
    final (record, rect) = resolved;
    final size = widget.size;
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3;
    final pixels = (size * ratio).round();
    // Resolved exactly like a grid tile — an avatar that fell back to the
    // person glyph while the same photo drew fine in the grid was this
    // path missing the thumbnail cache. Decoded at the circle's size,
    // never the original's (UI-9).
    whole() =>
        assetImage(record, placeholder: _placeholder, fileDecodeSize: pixels);
    if (rect == null) return whole();
    // The whole photo holds the place while the crop decodes, and stands
    // in for good if it never does — a grey glyph there reads as "no
    // picture", which is the one thing this person definitely isn't.
    return _FaceCrop(
      record: record,
      face: rect,
      decodeWidth: decodeWidthForFace(rect, size, ratio),
      pixels: pixels,
      whole: whole,
    );
  }

  Widget _placeholder() => ColoredBox(
    color: CupertinoColors.systemGrey4,
    child: Icon(
      CupertinoIcons.person_fill,
      size: widget.size * 0.6,
      color: CupertinoColors.white,
    ),
  );
}

/// The cap: ~7 MB decoded at 4:3, against 48 MB for a 12 MP original, and
/// held only until the crop is made.
const maxFaceDecode = 1536;

/// Paints the square around one face, blown up to fill the circle.
///
/// Drawn from the decoded photo rather than transformed on top of a
/// `BoxFit.cover` image: cover already crops by an amount that depends on
/// the photo's shape, and scaling about the face's own alignment point
/// leaves the face wherever it sat in the frame. Centre-frame — one person,
/// a portrait — that looks right by accident; anyone standing off to the
/// side of a group shot ends up half out of the circle, or missed entirely.
/// How wide to decode the *photo* so the *face* in it lands sharp.
///
/// A flat cap was the bug this replaces: 1024px of a whole frame is only a
/// hundred pixels of a face filling a tenth of it, blown up into a circle
/// three hundred device-pixels across. The face's share of the frame is
/// exactly what the scale has to account for — the smaller it is, the more
/// of the photo has to be decoded to keep it sharp.
///
/// Bounded at both ends: a full 12-megapixel decode per avatar is memory
/// spent on detail nobody can see, and a face filling the frame needs no
/// help at all.
///
/// Top-level so the arithmetic can be tested without a decoder, an image
/// or a screen.
int decodeWidthForFace(FaceRect face, double size, double pixelRatio) {
  final wanted = size * pixelRatio;
  final share = face.width <= 0 ? 1.0 : face.width;
  return (wanted / share).round().clamp(512, maxFaceDecode);
}

class _FaceCrop extends StatefulWidget {
  const _FaceCrop({
    required this.record,
    required this.face,
    required this.decodeWidth,
    required this.pixels,
    required this.whole,
  });

  final AssetRecord record;
  final FaceRect face;

  /// How wide to decode the photo — see [decodeWidthForFace].
  final int decodeWidth;

  /// The circle's side in device pixels: what the crop is kept at.
  final int pixels;

  /// The same photo, uncropped — shown until the crop is ready.
  final Widget Function() whole;

  @override
  State<_FaceCrop> createState() => _FaceCropState();
}

class _FaceCropState extends State<_FaceCrop> {
  ui.Image? _image;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  List<ImageProvider> _providers = const [];
  var _attempt = 0;
  var _key = '';
  var _holding = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_FaceCrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.localId != widget.record.localId ||
        oldWidget.face != widget.face ||
        oldWidget.pixels != widget.pixels) {
      _resolve();
    }
  }

  @override
  void dispose() {
    _detach();
    _free();
    _image?.dispose();
    super.dispose();
  }

  void _detach() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  void _show(ui.Image image) {
    _image?.dispose();
    _image = image;
  }

  void _free() {
    if (!_holding) return;
    _holding = false;
    decodeSlots.release();
  }

  /// A fling mounts and drops tiles faster than photos decode: wait for
  /// the scroll to slow, then for a slot.
  Future<bool> _turn(String key) async {
    await null; // out of initState: the scroll physics read the view
    while (mounted &&
        _key == key &&
        Scrollable.recommendDeferredLoadingForContext(context)) {
      await SchedulerBinding.instance.endOfFrame;
    }
    if (!mounted || _key != key) return false;
    await decodeSlots.acquire();
    if (!mounted || _key != key) {
      decodeSlots.release();
      return false;
    }
    _holding = true;
    return true;
  }

  Future<void> _resolve() async {
    _detach();
    _free();
    final record = widget.record;
    final key =
        '${record.localId}|${widget.face.encode()}|${widget.pixels}|'
        '${record.updatedAt.millisecondsSinceEpoch}';
    _key = key;
    if (faceCrops.take(key) case final held?) {
      setState(() => _show(held));
      return;
    }
    // Last launch's crop: a small file, not a photo decode.
    if (await faceCropDisk.read(key) case final saved?) {
      if (!mounted || _key != key) {
        saved.dispose();
        return;
      }
      faceCrops.put(key, saved);
      setState(() => _show(saved.clone()));
      return;
    }
    if (!mounted || _key != key) return;
    if (!await _turn(key)) return;
    final providers = await assetImageProviders(
      record,
      fittedSize: widget.decodeWidth,
    );
    if (!mounted || _key != key) {
      _free();
      return;
    }
    _providers = providers;
    _attempt = 0;
    _load();
  }

  /// Each source in turn: one that won't decode hands over to the next,
  /// same fallback order the grid tiles draw with.
  void _load() {
    _detach();
    if (_attempt >= _providers.length) {
      _free();
      return;
    }
    final key = _key;
    final provider = ResizeImage(
      _providers[_attempt],
      width: widget.decodeWidth,
      allowUpscaling: false,
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        _detach();
        unawaited(_crop(provider, info, key));
      },
      onError: (error, stackTrace) {
        if (!mounted) return;
        _attempt++;
        _load();
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  /// Keeps only the circle's worth of pixels: the bounded render is
  /// dropped from the image cache as soon as the crop is made, so a row
  /// of avatars holds a row of small squares rather than a row of photos.
  Future<void> _crop(ImageProvider provider, ImageInfo info, String key) async {
    final ui.Image crop;
    try {
      crop = await cropFace(info.image, widget.face, widget.pixels);
    } catch (_) {
      return;
    } finally {
      info.dispose();
      unawaited(provider.evict());
      if (_key == key) _free();
    }
    faceCrops.put(key, crop);
    unawaited(faceCropDisk.write(key, crop));
    if (!mounted || _key != key) return;
    setState(() => _show(crop.clone()));
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return widget.whole();
    return RawImage(
      image: image,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// [faceCropRect] of [image], scaled to a [pixels] square. Drawn on the
/// raster thread; the UI isolate only records one draw call.
Future<ui.Image> cropFace(ui.Image image, FaceRect face, int pixels) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    image,
    faceCropRect(Size(image.width.toDouble(), image.height.toDouble()), face),
    Rect.fromLTWH(0, 0, pixels.toDouble(), pixels.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  return picture.toImage(pixels, pixels).whenComplete(picture.dispose);
}

/// Face crops made this session, most recently used last, so an avatar
/// scrolled back in is drawn at once. ~300 KB each at 92 pt on a 3x screen.
final faceCrops = FaceCropCache(160);

/// Photos decoding for a crop at once, newest asker first: the tiles on
/// screen now, not the ones a scroll already passed.
final decodeSlots = DecodeSlots(3);

class DecodeSlots {
  DecodeSlots(this.size);

  final int size;
  var _used = 0;
  final _waiting = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_used < size) {
      _used++;
      return Future.value();
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    return turn.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeLast().complete();
    } else {
      _used--;
    }
  }
}

class FaceCropCache {
  FaceCropCache(this.capacity);

  final int capacity;
  final _held = <String, ui.Image>{};

  int get length => _held.length;

  /// A handle of its own for the caller to dispose, or null.
  ui.Image? take(String key) {
    final image = _held.remove(key);
    if (image == null) return null;
    _held[key] = image;
    return image.clone();
  }

  void put(String key, ui.Image image) {
    _held.remove(key)?.dispose();
    _held[key] = image;
    while (_held.length > capacity) {
      final oldest = _held.keys.first;
      _held.remove(oldest)!.dispose();
    }
  }

  void clear() {
    for (final image in _held.values) {
      image.dispose();
    }
    _held.clear();
  }
}

/// How much room to leave around a face box. Vision's rect hugs the
/// features, and a crop that tight is a nose and two eyes — the same
/// reasoning (and roughly the same number) as `FaceCrops.padding`.
const faceCropPadding = 0.5;

/// The square of a [image]-sized photo to draw for [face]: the face box
/// with room around it, never bigger than the photo's shorter side, and
/// slid back inside the frame rather than clipped at its edge — a face at
/// the frame's edge is exactly the group-shot case, and a short-sided crop
/// there stretches the face to fill the circle.
Rect faceCropRect(Size image, FaceRect face) {
  final side =
      (math.max(face.width * image.width, face.height * image.height) *
              (1 + faceCropPadding * 2))
          .clamp(1.0, math.min(image.width, image.height))
          .toDouble();
  final centre = Offset(
    (face.x + face.width / 2) * image.width,
    (face.y + face.height / 2) * image.height,
  );
  return Rect.fromLTWH(
    (centre.dx - side / 2).clamp(0.0, image.width - side),
    (centre.dy - side / 2).clamp(0.0, image.height - side),
    side,
    side,
  );
}
