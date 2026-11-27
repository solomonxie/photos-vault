import 'package:flutter/cupertino.dart';

/// A navigation bar that scrolls its page back to the top when tapped
/// anywhere that isn't one of its own buttons.
class TapToTopBar extends StatelessWidget
    implements ObstructingPreferredSizeWidget {
  const TapToTopBar({super.key, required this.bar, required this.onTap});

  final CupertinoNavigationBar bar;
  final VoidCallback onTap;

  @override
  Size get preferredSize => bar.preferredSize;

  @override
  bool shouldFullyObstruct(BuildContext context) =>
      bar.shouldFullyObstruct(context);

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: onTap,
    child: bar,
  );
}
