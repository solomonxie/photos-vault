import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/smaller_export.dart';

void main() {
  test('the longest edge is brought down to the chosen size', () {
    expect(fitWithin(4032, 3024, 1280), (1280, 960));
    expect(fitWithin(3024, 4032, 640), (480, 640));
  });

  test('a photo already small enough is left at its size', () {
    expect(fitWithin(800, 600, 1280), (800, 600));
  });
}
