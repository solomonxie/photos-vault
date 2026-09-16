import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

/// A storage silo — the shape every object-storage vendor draws, and the
/// one thing "Private Cloud" is actually about.
///
/// Hand-drawn because the Cupertino set has no bucket, cylinder or silo in
/// it, and the row was making do with a gear: the same glyph as every
/// settings screen ever made, saying nothing about what's behind the row.
/// A cloud would have been the other obvious choice and is worse — the
/// whole point of this screen is storage that *isn't* somebody else's
/// cloud.
class BucketGlyph extends StatelessWidget {
  const BucketGlyph({
    super.key,
    this.size = 17,
    this.color = CupertinoColors.white,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _BucketPainter(color)),
  );
}

class _BucketPainter extends CustomPainter {
  const _BucketPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.095
      ..strokeCap = StrokeCap.round;

    // Inset by the stroke so the silhouette doesn't clip against the tile.
    final inset = paint.strokeWidth / 2;
    final width = size.width - inset * 2;
    final height = size.height - inset * 2;
    final radiusY = height * 0.17;
    final left = inset;
    final right = inset + width;
    final top = inset;
    final bottom = inset + height;

    // The lid, drawn whole — a silo read from slightly above.
    canvas.drawOval(Rect.fromLTRB(left, top, right, top + radiusY * 2), paint);
    canvas.drawLine(
      Offset(left, top + radiusY),
      Offset(left, bottom - radiusY),
      paint,
    );
    canvas.drawLine(
      Offset(right, top + radiusY),
      Offset(right, bottom - radiusY),
      paint,
    );
    // Only the front half of the base: the back of it is behind the silo.
    canvas.drawArc(
      Rect.fromLTRB(left, bottom - radiusY * 2, right, bottom),
      0,
      math.pi,
      false,
      paint,
    );
    // One band across the middle, which is what stops it reading as a
    // plain cylinder and starts it reading as a container of something.
    canvas.drawArc(
      Rect.fromLTRB(
        left,
        top + height * 0.36,
        right,
        top + height * 0.36 + radiusY * 2,
      ),
      0,
      math.pi,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_BucketPainter oldDelegate) => oldDelegate.color != color;
}
