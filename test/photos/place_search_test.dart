import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/place_search.dart';
import 'package:photos_vault/viewer/native_map.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/places');

  test('search reads MapKit results and skips malformed ones', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'search');
          expect((call.arguments as Map)['query'], 'kyoto');
          return [
            {
              'name': 'Kyoto',
              'locality': 'Kyoto',
              'country': 'Japan',
              'lat': 35.0,
              'lng': 135.7,
              'isCity': true,
            },
            {'name': 'broken'},
          ];
        });
    final results = await PlaceSearch(channel: channel).search('kyoto');
    expect(results.single.name, 'Kyoto');
    expect(results.single.isCity, isTrue);
  });

  test('no native side: empty, not an error', () async {
    final search = PlaceSearch(channel: const MethodChannel('test/none'));
    expect(await search.search('x'), isEmpty);
    expect(
      await search.snapshot(pins: const [MapPinData(id: 'a', lat: 1, lng: 2)]),
      isNull,
    );
  });

  testWidgets('the map is a placeholder where MapKit is absent', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CupertinoApp(
        home: NativeMap(pins: [MapPinData(id: 'a', lat: 1, lng: 2)]),
      ),
    );
    expect(find.byKey(const ValueKey('nativeMapPlaceholder')), findsOne);
  });
}
