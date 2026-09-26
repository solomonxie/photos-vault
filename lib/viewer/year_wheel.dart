import 'package:flutter/cupertino.dart';

/// A year, and only a year.
///
/// For schooling and jobs, where a day and a month are precision nobody has:
/// almost nobody remembers the date they started a job, and offering a full
/// wheel invites an answer more exact than the truth. A year is what people
/// actually know.
///
/// Reports 1 January of the year picked, so entries written with a full date
/// keep it in the database and simply display as their year — no migration,
/// and nothing already recorded is coarsened.
class YearWheel extends StatelessWidget {
  const YearWheel({
    super.key,
    required this.initial,
    required this.onChanged,
    this.earliest = 1900,
  });

  final DateTime initial;
  final ValueChanged<DateTime> onChanged;
  final int earliest;

  @override
  Widget build(BuildContext context) {
    final latest = DateTime.now().year;
    final years = [for (var y = latest; y >= earliest; y--) y];
    final start = years.indexOf(initial.year.clamp(earliest, latest));
    return CupertinoPicker(
      scrollController: FixedExtentScrollController(
        initialItem: start < 0 ? 0 : start,
      ),
      itemExtent: 36,
      onSelectedItemChanged: (index) => onChanged(DateTime(years[index])),
      children: [
        for (final year in years)
          Center(child: Text('$year', style: const TextStyle(fontSize: 20))),
      ],
    );
  }
}
