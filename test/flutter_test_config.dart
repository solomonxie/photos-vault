import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// No iOS encoder under test: answers "not encoded" at once. Unanswered, a
/// call waits on the real engine, which a widget test's fake clock never
/// reaches.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('byo.photos/image_encode'),
        (_) async => null,
      );
  await testMain();
}
