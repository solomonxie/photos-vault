import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';

import '../photos/person.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';

/// A person's profile picture — resolved on demand from their
/// `avatarLocalId` (one of their own tagged photos, not a separate upload),
/// cropped to [face] when the photo is a group shot and only part of it is
/// them. Falls back to a plain person glyph until resolved or if there's
/// none.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.assetRecordStore,
    required this.localId,
    this.face,
    this.size = 64,
  });

  /// Their chosen picture, or — until one's been chosen — the first photo
  /// they're tagged in: somebody with photos should never sit behind a grey
  /// glyph. A face box only means anything on the photo it was tapped in,
  /// so it's dropped along with the photo.
  factory PersonAvatar.forPerson({
    required AssetRecordStore assetRecordStore,
    required Person person,
    String? firstTaggedLocalId,
    double size = 64,
  }) => PersonAvatar(
    assetRecordStore: assetRecordStore,
    localId: person.avatarLocalId ?? firstTaggedLocalId,
    face: person.avatarLocalId == null ? null : person.avatarFace,
    size: size,
  );

  final AssetRecordStore assetRecordStore;
  final String? localId;

  /// Which part of the photo is this person — see [Person.avatarFace].
  /// Null shows the whole photo, centre-cropped to the circle.
  final FaceRect? face;
  final double size;

  @override
  Widget build(BuildContext context) {
    final id = localId;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: id == null
            ? _placeholder()
            : FutureBuilder<AssetRecord?>(
                future: assetRecordStore.getByLocalId(id),
                builder: (context, snapshot) {
                  final record = snapshot.data;
                  if (record == null) return _placeholder();
                  // Resolved exactly like a grid tile — an avatar that
                  // fell back to the person glyph while the same photo drew
                  // fine in the grid was this path missing the thumbnail
                  // cache.
                  whole() => assetImage(record, placeholder: _placeholder);
                  final rect = face;
                  if (rect == null) return whole();
                  // The whole photo holds the place while the crop decodes,
                  // and stands in for good if it never does — a grey glyph
                  // there reads as "no picture", which is the one thing
                  // this person definitely isn't.
                  return _FaceCrop(
                    record: record,
                    face: rect,
                    size: size,
                    whole: whole,
                  );
                },
              ),
      ),
    );
  }

  Widget _placeholder() => ColoredBox(
    color: CupertinoColors.systemGrey4,
    child: Icon(
      CupertinoIcons.person_fill,
      size: size * 0.6,
      color: CupertinoColors.white,
    ),
  );
}

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
  return (wanted / share).round().clamp(512, 3072);
}

class _FaceCrop extends StatefulWidget {
  const _FaceCrop({
    required this.record,
    required this.face,
    required this.size,
    required this.whole,
  });

  final AssetRecord record;
  final FaceRect face;

  /// How big the circle is drawn, in points — half of what decides how
  /// much of the photo is worth decoding. See [decodeWidthForFace].
  final double size;

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

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_FaceCrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.localId != widget.record.localId) _resolve();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  Future<void> _resolve() async {
    final providers = await assetImageProviders(widget.record);
    if (!mounted) return;
    _providers = providers;
    _attempt = 0;
    _load();
  }

  /// Each source in turn: one that won't decode hands over to the next,
  /// same fallback order the grid tiles draw with.
  void _load() {
    _detach();
    if (_attempt >= _providers.length) return;
    final provider = ResizeImage(
      _providers[_attempt],
      width: decodeWidthForFace(
        widget.face,
        widget.size,
        MediaQuery.maybeDevicePixelRatioOf(context) ?? 3,
      ),
      allowUpscaling: false,
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() => _image = info.image);
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

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return widget.whole();
    return CustomPaint(
      painter: _FaceCropPainter(image: image, face: widget.face),
      size: Size.infinite,
    );
  }
}

class _FaceCropPainter extends CustomPainter {
  const _FaceCropPainter({required this.image, required this.face});

  final ui.Image image;
  final FaceRect face;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      faceCropRect(Size(image.width.toDouble(), image.height.toDouble()), face),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_FaceCropPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.face != face;
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
