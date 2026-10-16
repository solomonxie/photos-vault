import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/year_wheel.dart';

void main() {
  testWidgets('a rebuild keeps the year scrolled to', (tester) async {
    DateTime? picked;
    late StateSetter rebuild;
    await tester.pumpWidget(
      CupertinoApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Center(
              child: SizedBox(
                height: 200,
                child: YearWheel(
                  initial: DateTime(2000),
                  onChanged: (d) => picked = d,
                ),
              ),
            );
          },
        ),
      ),
    );
    expect(find.text('2000'), findsOneWidget);

    await tester.drag(find.byType(CupertinoPicker), const Offset(0, -72));
    await tester.pumpAndSettle();
    final year = picked!.year;
    expect(year, lessThan(2000));

    rebuild(() {});
    await tester.pumpAndSettle();
    final controller = tester
        .widget<CupertinoPicker>(find.byType(CupertinoPicker))
        .scrollController!;
    expect(DateTime.now().year - controller.selectedItem, year);
  });
}
