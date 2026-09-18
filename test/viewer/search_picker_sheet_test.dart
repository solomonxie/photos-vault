import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/search_picker_sheet.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

const _screen = Size(393, 852);

Future<void> _openPicker(
  WidgetTester tester, {
  required Set<String> options,
}) async {
  await tester.binding.setSurfaceSize(_screen);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    CupertinoApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Center(
          child: CupertinoButton(
            onPressed: () => showSearchPickerSheet(
              context: context,
              title: 'Region',
              options: options,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Set<String> _regions(int count) => {
  for (var i = 0; i < count; i++) 'ap-region-$i',
};

double _sheetHeight(WidgetTester tester) =>
    tester.getSize(find.byKey(searchPickerSheetKey)).height;

void main() {
  testWidgets('a long list still leaves half the page showing', (tester) async {
    await _openPicker(tester, options: _regions(30));

    expect(_sheetHeight(tester), lessThanOrEqualTo(_screen.height / 2));
  });

  testWidgets('a short list gets a sheet sized to it, not the cap', (
    tester,
  ) async {
    await _openPicker(tester, options: {'ap-guangzhou', 'ap-shanghai'});

    expect(_sheetHeight(tester), lessThan(_screen.height / 3));
  });

  testWidgets('a list worth scanning opens without the keyboard', (
    tester,
  ) async {
    await _openPicker(tester, options: {'ap-guangzhou', 'ap-shanghai'});

    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('a list too long to scan opens ready to type', (tester) async {
    await _openPicker(tester, options: _regions(30));

    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('dragging the grabber down dismisses it', (tester) async {
    await _openPicker(tester, options: _regions(30));

    await tester.drag(find.text('Region'), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(find.byKey(searchPickerSheetKey), findsNothing);
  });

  testWidgets('pulling the list down past its top dismisses it too', (
    tester,
  ) async {
    await _openPicker(tester, options: _regions(30));

    await tester.drag(find.text('ap-region-1'), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(find.byKey(searchPickerSheetKey), findsNothing);
  });

  testWidgets('a drag that changed its mind springs back', (tester) async {
    await _openPicker(tester, options: _regions(30));
    final top = tester.getTopLeft(find.byKey(searchPickerSheetKey)).dy;

    await tester.drag(find.text('Region'), const Offset(0, 30));
    await tester.pumpAndSettle();

    expect(find.byKey(searchPickerSheetKey), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(searchPickerSheetKey)).dy, top);
  });
}
