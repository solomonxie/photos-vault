import 'package:flutter/cupertino.dart';

/// Opens a page by growing it out of the middle of the screen rather than
/// sliding it in from the edge — what opening a photo should feel like.
///
/// A sideways push reads as "somewhere else in the app"; a photo isn't
/// somewhere else, it's the thing you just tapped, bigger. The scale starts
/// close to full size (a big zoom reads as a transition of its own rather
/// than as the photo opening) and the fade carries the rest.
class ZoomPageRoute<T> extends PageRoute<T> {
  ZoomPageRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  /// Shorter than the opening, because the two are not the same event.
  /// Opening is worth watching — the photo grows out of the grid. Closing
  /// is a photo already thrown away: whatever time the animation takes is
  /// time the grid isn't back yet, and the tail of a cubic fade is a ghost
  /// of a photo nobody is looking at any more.
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 140);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.88, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}
