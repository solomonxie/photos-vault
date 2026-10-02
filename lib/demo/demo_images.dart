import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Photo-like landscapes for the demo library, drawn rather than bundled:
/// nothing to license, nothing added to the app's size, and the same seed
/// draws the same picture every time. Pure Dart, for `Isolate.run`.
///
/// Scenes: sunset, beach, mountains, lake, forest, city, desert, snow.
Uint8List renderDemoPhoto({
  required String scene,
  required int seed,
  int width = 960,
  int height = 720,
}) {
  final random = math.Random(seed);
  final palette = _palettes[scene] ?? _palettes['mountains']!;
  final px = Uint8List(width * height * 3);

  final horizon = height * (0.52 + random.nextDouble() * 0.12);
  final sunX = width * (0.2 + random.nextDouble() * 0.6);
  final sunY = scene == 'sunset' || scene == 'desert'
      ? horizon - height * 0.06
      : height * (0.14 + random.nextDouble() * 0.12);
  final sunR = width * (scene == 'city' ? 0.025 : 0.05);
  final phase = [for (var i = 0; i < 4; i++) random.nextDouble() * 6.28];
  final water = palette.water != null;

  List<double> ridge(int layer, double base, double amp, double freq) => [
    for (var x = 0; x < width; x++)
      base -
          amp *
              (0.6 * math.sin(x / width * freq * 6.28 + phase[layer % 4]) +
                  0.3 * math.sin(x / width * freq * 15.1 + phase[3]) +
                  0.1 * math.sin(x / width * freq * 41.0 + layer)),
  ];

  // Back to front: each later layer covers the ones before it.
  final layers = <(List<double>, List<int>)>[];
  switch (scene) {
    case 'city':
      for (var l = 0; l < 2; l++) {
        final tops = List<double>.filled(width, horizon);
        var x = 0;
        while (x < width) {
          final w = 30 + random.nextInt(70);
          final top =
              horizon - height * (0.12 + random.nextDouble() * 0.3) / (l + 1);
          for (var i = x; i < math.min(width, x + w); i++) {
            tops[i] = top + l * height * 0.08;
          }
          x += w + random.nextInt(8);
        }
        layers.add((tops, palette.layers[l]));
      }
    case 'forest' || 'snow':
      layers.add((
        ridge(0, horizon - height * 0.1, height * 0.08, 1.3),
        palette.layers[0],
      ));
      for (var l = 1; l < 3; l++) {
        final period = 22.0 + l * 10;
        final base = horizon + l * height * 0.07;
        layers.add((
          [
            for (var x = 0; x < width; x++)
              base -
                  height *
                      0.12 *
                      (1 - ((x + phase[l] * 40) % period) / period * 2).abs() -
                  height * 0.02 * math.sin(x / 37.0 + l),
          ],
          palette.layers[l],
        ));
      }
    default:
      layers.add((
        ridge(0, horizon - height * 0.08, height * 0.12, 1.1),
        palette.layers[0],
      ));
      layers.add((
        ridge(1, horizon - height * 0.02, height * 0.06, 2.3),
        palette.layers[1],
      ));
      if (!water) {
        layers.add((
          ridge(2, horizon + height * 0.12, height * 0.04, 1.7),
          palette.layers[2],
        ));
      }
  }

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      List<int> c;
      if (water && y > horizon) {
        // A reflection of the sky, darkened and rippled.
        final mirror = (2 * horizon - y).clamp(0, height - 1).toDouble();
        final ripple = math.sin(y * 0.9 + x * 0.02 + phase[1]) * 3;
        c = _mix(
          _sky(palette, (mirror + ripple) / horizon),
          palette.water!,
          0.55,
        );
      } else {
        c = _sky(palette, y / horizon);
        final d = math.sqrt(math.pow(x - sunX, 2) + math.pow(y - sunY, 2));
        if (d < sunR) {
          c = palette.sun;
        } else {
          c = _mix(c, palette.sun, math.exp(-(d - sunR) / (sunR * 2.2)) * 0.6);
        }
      }
      for (final (tops, color) in layers) {
        // Hills stop at the shore; below it is the water.
        if (y >= tops[x] && !(water && y > horizon)) {
          final depth = ((y - tops[x]) / height).clamp(0.0, 1.0);
          c = _mix(color, const [0, 0, 0], depth * 0.5);
          if (scene == 'city' && color == palette.layers[1]) {
            final cell = (x ~/ 9) * 73856093 ^ (y ~/ 13) * 19349663 ^ seed;
            final lit = ((cell * 2654435761) >> 16) % 5 < 2;
            if (lit && x % 9 > 2 && y % 13 > 4) c = const [255, 214, 120];
          }
        }
      }
      if (scene == 'beach' && y > horizon + height * 0.16) {
        c = palette.layers[2];
      }
      final grain = random.nextInt(9) - 4;
      final i = (y * width + x) * 3;
      px[i] = (c[0] + grain).clamp(0, 255);
      px[i + 1] = (c[1] + grain).clamp(0, 255);
      px[i + 2] = (c[2] + grain).clamp(0, 255);
    }
  }

  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: px.buffer,
    numChannels: 3,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 86));
}

class _Palette {
  const _Palette({
    required this.skyTop,
    required this.skyBottom,
    required this.sun,
    required this.layers,
    this.water,
  });

  final List<int> skyTop;
  final List<int> skyBottom;
  final List<int> sun;
  final List<List<int>> layers;
  final List<int>? water;
}

List<int> _sky(_Palette p, double t) =>
    _mix(p.skyTop, p.skyBottom, t.clamp(0.0, 1.0));

List<int> _mix(List<int> a, List<int> b, double t) => [
  for (var i = 0; i < 3; i++) (a[i] + (b[i] - a[i]) * t).round(),
];

const _palettes = {
  'sunset': _Palette(
    skyTop: [38, 52, 120],
    skyBottom: [250, 146, 72],
    sun: [255, 228, 160],
    layers: [
      [92, 56, 104],
      [54, 34, 70],
      [30, 20, 40],
    ],
    water: [40, 30, 70],
  ),
  'beach': _Palette(
    skyTop: [56, 150, 230],
    skyBottom: [210, 236, 250],
    sun: [255, 252, 230],
    layers: [
      [120, 160, 150],
      [80, 130, 120],
      [238, 214, 160],
    ],
    water: [20, 120, 180],
  ),
  'mountains': _Palette(
    skyTop: [70, 130, 210],
    skyBottom: [215, 230, 245],
    sun: [255, 250, 225],
    layers: [
      [150, 165, 190],
      [90, 110, 130],
      [70, 120, 60],
    ],
  ),
  'lake': _Palette(
    skyTop: [120, 150, 210],
    skyBottom: [250, 200, 190],
    sun: [255, 240, 210],
    layers: [
      [90, 120, 110],
      [40, 80, 60],
      [30, 60, 40],
    ],
    water: [50, 80, 110],
  ),
  'forest': _Palette(
    skyTop: [150, 190, 220],
    skyBottom: [230, 236, 220],
    sun: [255, 250, 230],
    layers: [
      [120, 150, 130],
      [40, 90, 55],
      [20, 60, 35],
    ],
  ),
  'city': _Palette(
    skyTop: [14, 18, 48],
    skyBottom: [120, 70, 120],
    sun: [240, 240, 250],
    layers: [
      [50, 50, 80],
      [28, 28, 46],
    ],
  ),
  'desert': _Palette(
    skyTop: [90, 150, 210],
    skyBottom: [250, 210, 160],
    sun: [255, 236, 190],
    layers: [
      [214, 160, 100],
      [196, 132, 76],
      [170, 106, 56],
    ],
  ),
  'snow': _Palette(
    skyTop: [150, 180, 220],
    skyBottom: [235, 240, 248],
    sun: [255, 255, 245],
    layers: [
      [225, 232, 242],
      [40, 70, 60],
      [25, 50, 42],
    ],
  ),
};
