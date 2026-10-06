import 'package:flutter/cupertino.dart';

/// Grey boxes where the photo grid will be, for the moment the database is
/// still being read. Static on purpose: no animation to repaint while the
/// first real frame is the thing that needs the time.
class GridSkeleton extends StatelessWidget {
  const GridSkeleton({super.key});

  static const _columns = 3;
  static const _spacing = 8.0;
  static const _padding = 8.0;
  static const _fill = Color(0xFF2C2C2E);

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final tile =
            (constraints.maxWidth - 2 * _padding - (_columns - 1) * _spacing) /
            _columns;
        final rows = (height / (tile + _spacing)).ceil();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: _padding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: _Box(width: 96, height: 14),
              ),
              for (var r = 0; r < rows; r++)
                Padding(
                  padding: const EdgeInsets.only(bottom: _spacing),
                  child: Row(
                    children: [
                      for (var c = 0; c < _columns; c++) ...[
                        if (c > 0) const SizedBox(width: _spacing),
                        _Box(width: tile, height: tile),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: const DecoratedBox(
      decoration: BoxDecoration(
        color: GridSkeleton._fill,
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
    ),
  );
}
