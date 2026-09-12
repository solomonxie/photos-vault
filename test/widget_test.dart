import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:back_your_own_photos/app.dart';

void main() {
  testWidgets('shows the three main tab destinations', (tester) async {
    await tester.pumpWidget(const App());

    expect(find.byIcon(Icons.photo_library), findsOneWidget);
    expect(find.byIcon(Icons.cloud_upload), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
  });
}
