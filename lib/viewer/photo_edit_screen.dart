import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/photo_editor.dart';

enum PhotoEditMode { crop, rotate }

/// Crop/rotate editor over one still image. Pops the edited bytes (already
/// re-encoded in the source's format), or `null` if the user cancels —
/// where those bytes end up (in place, or as a new library item) is the
/// caller's call.
class PhotoEditScreen extends StatefulWidget {
  const PhotoEditScreen({super.key, required this.file, required this.mode});

  final File file;
  final PhotoEditMode mode;

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
    final bytes = await widget.file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _imageSize = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
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
                    onPressed: () => Navigator.of(context).pop(),
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
                  ? const Center(child: CupertinoActivityIndicator())
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: widget.mode == PhotoEditMode.rotate
                          ? Center(
                              child: Transform.rotate(
                                angle: _angle * math.pi / 180,
                                child: Image.memory(bytes),
                              ),
                            )
                          : _CropCanvas(
                              bytes: bytes,
                              imageAspect: size.width / size.height,
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
/// resize, drag inside to move, everything outside dims.
class _CropCanvas extends StatelessWidget {
  const _CropCanvas({
    required this.bytes,
    required this.imageAspect,
    required this.crop,
    required this.onChanged,
  });

  final Uint8List bytes;
  final double imageAspect;
  final Rect crop;
  final ValueChanged<Rect> onChanged;

  static const _handleTouchRadius = 44.0;
  static const _minSide = 0.08;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var width = constraints.maxWidth;
        var height = width / imageAspect;
        if (height > constraints.maxHeight) {
          height = constraints.maxHeight;
          width = height * imageAspect;
        }
        final view = Size(width, height);
        final rect = Rect.fromLTRB(
          crop.left * width,
          crop.top * height,
          crop.right * width,
          crop.bottom * height,
        );

        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: _CropGestureLayer(
              view: view,
              rect: rect,
              onChanged: (next) => onChanged(
                Rect.fromLTRB(
                  next.left / width,
                  next.top / height,
                  next.right / width,
                  next.bottom / height,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(bytes, fit: BoxFit.fill),
                  CustomPaint(painter: _CropPainter(rect)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Which part of the crop rect a drag grabbed.
enum _Grab { topLeft, topRight, bottomLeft, bottomRight, inside }

class _CropGestureLayer extends StatefulWidget {
  const _CropGestureLayer({
    required this.view,
    required this.rect,
    required this.onChanged,
    required this.child,
  });

  final Size view;
  final Rect rect;
  final ValueChanged<Rect> onChanged;
  final Widget child;

  @override
  State<_CropGestureLayer> createState() => _CropGestureLayerState();
}

class _CropGestureLayerState extends State<_CropGestureLayer> {
  _Grab? _grab;

  _Grab _grabAt(Offset point) {
    final corners = {
      _Grab.topLeft: widget.rect.topLeft,
      _Grab.topRight: widget.rect.topRight,
      _Grab.bottomLeft: widget.rect.bottomLeft,
      _Grab.bottomRight: widget.rect.bottomRight,
    };
    for (final entry in corners.entries) {
      if ((entry.value - point).distance <= _CropCanvas._handleTouchRadius) {
        return entry.key;
      }
    }
    return _Grab.inside;
  }

  void _apply(Offset delta, Offset point) {
    final min = _CropCanvas._minSide * widget.view.shortestSide;
    var rect = widget.rect;
    switch (_grab!) {
      case _Grab.topLeft:
        rect = Rect.fromLTRB(point.dx, point.dy, rect.right, rect.bottom);
      case _Grab.topRight:
        rect = Rect.fromLTRB(rect.left, point.dy, point.dx, rect.bottom);
      case _Grab.bottomLeft:
        rect = Rect.fromLTRB(point.dx, rect.top, rect.right, point.dy);
      case _Grab.bottomRight:
        rect = Rect.fromLTRB(rect.left, rect.top, point.dx, point.dy);
      case _Grab.inside:
        rect = rect.shift(delta);
        final dx =
            rect.left.clamp(0.0, widget.view.width - rect.width) - rect.left;
        final dy =
            rect.top.clamp(0.0, widget.view.height - rect.height) - rect.top;
        rect = rect.shift(Offset(dx, dy));
    }
    final clamped = Rect.fromLTRB(
      rect.left.clamp(0.0, rect.right - min),
      rect.top.clamp(0.0, rect.bottom - min),
      rect.right.clamp(rect.left + min, widget.view.width),
      rect.bottom.clamp(rect.top + min, widget.view.height),
    );
    widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (details) => _grab = _grabAt(details.localPosition),
      onPanUpdate: (details) {
        if (_grab == null) return;
        _apply(details.delta, details.localPosition);
      },
      onPanEnd: (_) => _grab = null,
      child: widget.child,
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Paint()..color = const Color(0x99000000);
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(rect),
      ),
      scrim,
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
  bool shouldRepaint(_CropPainter oldDelegate) => oldDelegate.rect != rect;
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
