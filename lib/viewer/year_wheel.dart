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
class YearWheel extends StatefulWidget {
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
  State<YearWheel> createState() => _YearWheelState();
}

class _YearWheelState extends State<YearWheel> {
  late final int _latest = DateTime.now().year;
  late final List<int> _years = [
    for (var y = _latest; y >= widget.earliest; y--) y,
  ];
  late final FixedExtentScrollController _controller =
      FixedExtentScrollController(
        initialItem:
            _latest - widget.initial.year.clamp(widget.earliest, _latest),
      );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPicker(
    scrollController: _controller,
    itemExtent: 36,
    onSelectedItemChanged: (index) => widget.onChanged(DateTime(_years[index])),
    children: [
      for (final year in _years)
        Center(child: Text('$year', style: const TextStyle(fontSize: 20))),
    ],
  );
}
