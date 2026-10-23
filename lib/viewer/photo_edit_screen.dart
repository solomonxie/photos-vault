import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/photo_editor.dart';
import 'encoded_image_size.dart';

enum PhotoEditMode { crop, rotate }

/// The preview never needs more pixels than the screen has.
int _previewWidth(BuildContext context) =>
    (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context))
        .round();

/// Crop/rotate editor over one still image. Pops the edited bytes (already
/// re-encoded in the source's format), or `null` if the user cancels —
/// where those bytes end up (in place, or as a new library item) is the
/// caller's call.
class PhotoEditScreen extends StatefulWidget {
  const PhotoEditScreen({
    super.key,
    required this.file,
    required this.mode,
    this.readBytes,
  });

  final File file;
  final PhotoEditMode mode;

  /// Overridable for tests — real file I/O never completes under
  /// `testWidgets`' fake async.
  final Future<Uint8List> Function(File file)? readBytes;

  @override
  State<PhotoEditScreen> createState() => _PhotoEditScreenState();
}

class _PhotoEditScreenState extends State<PhotoEditScreen> {
  Uint8List? _bytes;
  Size? _imageSize;
  bool _saving = false;
  String? _error;

  /// Rotate mode, in degrees clockwise.
  double _angle = 0;

  /// Crop mode, as 0..1 fractions of the source image.
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final read = widget.readBytes ?? (file) => file.readAsBytes();
    Uint8List? bytes;
    Size? size;
    try {
      bytes = await read(widget.file);
      size = await encodedImageSize(bytes);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      if (size == null || size.isEmpty) {
        _error = AppLocalizations.of(context)!.editFailed;
        return;
      }
      _bytes = bytes;
      _imageSize = size;
    });
  }

  bool get _dirty => widget.mode == PhotoEditMode.rotate
      ? _angle % 360 != 0
      : _crop != const Rect.fromLTRB(0, 0, 1, 1);

  Future<void> _save() async {
    final bytes = _bytes;
    if (bytes == null || _saving) return;
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    final extension = _extensionOf(widget.file.path);
    final edited = widget.mode == PhotoEditMode.rotate
        ? await rotateImage(bytes: bytes, degrees: _angle, extension: extension)
        : await cropImage(bytes: bytes, fraction: _crop, extension: extension);
    if (!mounted) return;
    if (edited == null) {
      setState(() {
        _saving = false;
        _error = AppLocalizations.of(context)!.editFailed;
      });
      return;
    }
    Navigator.of(context).pop(edited);
  }

  /// As in Photos: an edit made isn't thrown away on one tap.
  Future<void> _cancel() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final discard = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(sheet).pop(true),
            child: Text(l10n.editDiscard),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(false),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    return dot == -1 ? '.jpg' : path.substring(dot);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bytes = _bytes;
    final size = _imageSize;

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _cancel,
                    child: Text(
                      l10n.actionCancel,
                      style: const TextStyle(color: CupertinoColors.white),
                    ),
                  ),
                  Text(
                    widget.mode == PhotoEditMode.rotate
                        ? l10n.detailEditRotateOption
                        : l10n.detailEditCropOption,
                    style: const TextStyle(
                      color: CupertinoColors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _saving ? null : _save,
                    child: Text(
                      l10n.editSaveButton,
                      style: const TextStyle(color: CupertinoColors.activeBlue),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: bytes == null || size == null
                  ? (_error == null
                        ? const Center(child: CupertinoActivityIndicator())
                        : const SizedBox.shrink())
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: widget.mode == PhotoEditMode.rotate
                          ? Center(
                              child: Transform.rotate(
                                angle: _angle * math.pi / 180,
                                child: Image.memory(
                                  bytes,
                                  cacheWidth: _previewWidth(context),
                                ),
                              ),
                            )
                          : _CropCanvas(
                              bytes: bytes,
                              imageSize: size,
                              crop: _crop,
                              onChanged: (value) =>
                                  setState(() => _crop = value),
                            ),
                    ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: widget.mode == PhotoEditMode.rotate
                  ? _RotationDial(
                      angle: _angle,
                      onChanged: (value) => setState(() => _angle = value),
                      onReset: () => setState(() => _angle = 0),
                    )
                  : CupertinoButton(
                      onPressed: () => setState(
                        () => _crop = const Rect.fromLTRB(0, 0, 1, 1),
                      ),
                      child: Text(l10n.editResetButton),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The photo with a draggable crop rectangle over it: drag a corner to
/// resize, drag inside to move. Let go and the crop zooms to fill the view
/// with everything outside it nearly blacked out, as in Photos, so what
/// Save keeps is what's on screen. The framing holds still while a finger
/// is down, so the handle stays under it.
class _CropCanvas extends StatefulWidget {
  const _CropCanvas({
    required this.bytes,
    required this.imageSize,
    required this.crop,
    required this.onChanged,
  });

  final Uint8List bytes;
  final Size imageSize;

  /// 0..1 fractions of the image.
  final Rect crop;
  final ValueChanged<Rect> onChanged;

  @override
  State<_CropCanvas> createState() => _CropCanvasState();
}

/// Which part of the crop rect a drag grabbed.
enum _Grab { topLeft, topRight, bottomLeft, bottomRight, inside }

class _CropCanvasState extends State<_CropCanvas> {
  static const _handleTouchRadius = 44.0;
  static const _minSide = 0.08;

  /// Room left around the fitted crop, so a corner can still be dragged out.
  static const _margin = 24.0;

  _Grab? _grab;

  /// The crop the view was fitted around when the finger went down.
  Rect? _held;

  /// Where the image sits in the box this frame, for mapping touches.
  Rect _image = Rect.zero;
  Size _box = Size.zero;

  Rect _imageRectFor(Rect framing, Size box) {
    final aspect = widget.imageSize.width / widget.imageSize.height;
    final width = math.min(
      (box.width - 2 * _margin) / framing.width,
      (box.height - 2 * _margin) * aspect / framing.height,
    );
    final height = width / aspect;
    final center = framing.center;
    return Rect.fromLTWH(
      box.width / 2 - center.dx * width,
      box.height / 2 - center.dy * height,
      width,
      height,
    );
  }

  Offset _toFraction(Offset local) => Offset(
    (local.dx - _image.left) / _image.width,
    (local.dy - _image.top) / _image.height,
  );

  Rect _onScreen(Rect fraction) => Rect.fromLTRB(
    _image.left + fraction.left * _image.width,
    _image.top + fraction.top * _image.height,
    _image.left + fraction.right * _image.width,
    _image.top + fraction.bottom * _image.height,
  );

  _Grab _grabAt(Offset point) {
    final rect = _onScreen(widget.crop);
    final corners = {
      _Grab.topLeft: rect.topLeft,
      _Grab.topRight: rect.topRight,
      _Grab.bottomLeft: rect.bottomLeft,
      _Grab.bottomRight: rect.bottomRight,
    };
    for (final entry in corners.entries) {
      if ((entry.value - point).distance <= _handleTouchRadius) {
        return entry.key;
      }
    }
    return _Grab.inside;
  }

  void _start(DragStartDetails details) => setState(() {
    _held = widget.crop;
    _grab = _grabAt(details.localPosition);
  });

  void _end() => setState(() {
    _held = null;
    _grab = null;
  });

  void _update(DragUpdateDetails details) {
    final grab = _grab;
    if (grab == null) return;
    // Only as far as the box shows: past it there is nothing to aim at.
    final visible = Rect.fromLTRB(
      math.max(0, -_image.left / _image.width),
      math.max(0, -_image.top / _image.height),
      math.min(1, (_box.width - _image.left) / _image.width),
      math.min(1, (_box.height - _image.top) / _image.height),
    );
    final minPx = _minSide * _image.shortestSide;
    final minX = minPx / _image.width;
    final minY = minPx / _image.height;
    final point = _toFraction(details.localPosition);
    final p = Offset(
      point.dx.clamp(visible.left, visible.right),
      point.dy.clamp(visible.top, visible.bottom),
    );
    var rect = widget.crop;
    switch (grab) {
      case _Grab.topLeft:
        rect = Rect.fromLTRB(
          math.min(p.dx, rect.right - minX),
          math.min(p.dy, rect.bottom - minY),
          rect.right,
          rect.bottom,
        );
      case _Grab.topRight:
        rect = Rect.fromLTRB(
          rect.left,
          math.min(p.dy, rect.bottom - minY),
          math.max(p.dx, rect.left + minX),
          rect.bottom,
        );
      case _Grab.bottomLeft:
        rect = Rect.fromLTRB(
          math.min(p.dx, rect.right - minX),
          rect.top,
          rect.right,
          math.max(p.dy, rect.top + minY),
        );
      case _Grab.bottomRight:
        rect = Rect.fromLTRB(
          rect.left,
          rect.top,
          math.max(p.dx, rect.left + minX),
          math.max(p.dy, rect.top + minY),
        );
      case _Grab.inside:
        final delta = Offset(
          details.delta.dx / _image.width,
          details.delta.dy / _image.height,
        );
        rect = rect.shift(delta);
        rect = rect.shift(
          Offset(
            rect.left.clamp(0.0, 1 - rect.width) - rect.left,
            rect.top.clamp(0.0, 1 - rect.height) - rect.top,
          ),
        );
    }
    widget.onChanged(
      Rect.fromLTRB(
        rect.left.clamp(0.0, 1.0),
        rect.top.clamp(0.0, 1.0),
        rect.right.clamp(0.0, 1.0),
        rect.bottom.clamp(0.0, 1.0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dragging = _held != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        final target = _held ?? widget.crop;
        // Decoded at the size it settles at, in steps, so a zoom doesn't
        // re-decode on every frame of the animation.
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final settledWidth = _imageRectFor(target, box).width * dpr;
        final cacheWidth = math.min(
          widget.imageSize.width.round(),
          ((settledWidth / 512).ceil() * 512),
        );
        return TweenAnimationBuilder<Rect?>(
          tween: RectTween(end: target),
          duration: dragging
              ? Duration.zero
              : const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          builder: (context, framing, _) {
            _box = box;
            _image = _imageRectFor(framing ?? target, box);
            return GestureDetector(
              onPanStart: _start,
              onPanUpdate: _update,
              onPanEnd: (_) => _end(),
              onPanCancel: _end,
              child: ClipRect(
                child: Stack(
                  children: [
                    Positioned.fromRect(
                      rect: _image,
                      child: Image.memory(
                        widget.bytes,
                        fit: BoxFit.fill,
                        cacheWidth: cacheWidth,
                        gaplessPlayback: true,
                      ),
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _CropPainter(
                          _onScreen(widget.crop),
                          scrim: dragging ? 0x99 : 0xE6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect, {required this.scrim});

  final Rect rect;

  /// Alpha of the black outside the crop.
  final int scrim;

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Paint()..color = Color.fromARGB(scrim, 0, 0, 0);
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(rect),
      ),
      shade,
    );

    final line = Paint()
      ..color = CupertinoColors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(rect, line);

    // Thirds guides, then the chunky corner brackets Photos uses.
    final guide = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 0.5;
    for (var i = 1; i < 3; i++) {
      final dx = rect.left + rect.width * i / 3;
      final dy = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(dx, rect.top), Offset(dx, rect.bottom), guide);
      canvas.drawLine(Offset(rect.left, dy), Offset(rect.right, dy), guide);
    }

    final bracket = Paint()
      ..color = CupertinoColors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    const arm = 20.0;
    for (final corner in [
      (rect.topLeft, const Offset(1, 0), const Offset(0, 1)),
      (rect.topRight, const Offset(-1, 0), const Offset(0, 1)),
      (rect.bottomLeft, const Offset(1, 0), const Offset(0, -1)),
      (rect.bottomRight, const Offset(-1, 0), const Offset(0, -1)),
    ]) {
      canvas.drawLine(corner.$1, corner.$1 + corner.$2 * arm, bracket);
      canvas.drawLine(corner.$1, corner.$1 + corner.$3 * arm, bracket);
    }
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.scrim != scrim;
}

/// A full 360° dial: spin it with a finger to set any angle, tap the
/// readout to snap back to 0.
class _RotationDial extends StatelessWidget {
  const _RotationDial({
    required this.angle,
    required this.onChanged,
    required this.onReset,
  });

  final double angle;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  static const _size = 120.0;

  void _updateFrom(Offset local) {
    const center = Offset(_size / 2, _size / 2);
    final vector = local - center;
    if (vector.distance < 8) return;
    final degrees = math.atan2(vector.dy, vector.dx) * 180 / math.pi + 90;
    onChanged((degrees + 360) % 360);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onPanDown: (d) => _updateFrom(d.localPosition),
          onPanUpdate: (d) => _updateFrom(d.localPosition),
          child: CustomPaint(
            size: const Size(_size, _size),
            painter: _DialPainter(angle),
          ),
        ),
        const SizedBox(height: 8),
        CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: onReset,
          child: Text(
            l10n.editAngleDegrees(angle.round().toString()),
            style: const TextStyle(
              color: CupertinoColors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter(this.angle);

  final double angle;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 6;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0xFF2C2C2E)
        ..style = PaintingStyle.fill,
    );

    final tick = Paint()..color = const Color(0x66FFFFFF);
    for (var i = 0; i < 24; i++) {
      final a = i * 15 * math.pi / 180;
      final outer = center + Offset(math.sin(a), -math.cos(a)) * radius;
      final inner =
          center +
          Offset(math.sin(a), -math.cos(a)) * (radius - (i % 6 == 0 ? 10 : 5));
      canvas.drawLine(inner, outer, tick..strokeWidth = i % 6 == 0 ? 2 : 1);
    }

    final a = angle * math.pi / 180;
    final knob = center + Offset(math.sin(a), -math.cos(a)) * (radius - 6);
    canvas.drawLine(
      center,
      knob,
      Paint()
        ..color = CupertinoColors.activeBlue
        ..strokeWidth = 2,
    );
    canvas.drawCircle(knob, 8, Paint()..color = CupertinoColors.activeBlue);
  }

  @override
  bool shouldRepaint(_DialPainter oldDelegate) => oldDelegate.angle != angle;
}
