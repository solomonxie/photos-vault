import 'dart:async';

import 'package:flutter/widgets.dart';

/// Makes the touch that stops a moving page *only* stop it.
///
/// iOS' rule: while a list is still travelling, the next touch is a brake —
/// it never opens the row it happens to land on. Flutter only half does
/// this: the viewport ignores pointers during a fling, but not while a
/// bounce settles, and not for anything drawn outside it. So a touch meant
/// to stop the page opens whatever was under the finger.
///
/// Mounted once, over the whole app. While a scroll the user started is
/// still in flight, a transparent layer on top takes the tap and drops it.
/// The touch still reaches the list underneath — it stops, and a drag that
/// follows still scrolls.
class ScrollStopGuard extends StatefulWidget {
  const ScrollStopGuard({super.key, required this.child});

  final Widget child;

  @override
  State<ScrollStopGuard> createState() => _ScrollStopGuardState();
}

class _ScrollStopGuardState extends State<ScrollStopGuard> {
  /// Kept out of `setState` on purpose: only the overlay listens, so every
  /// scroll start doesn't rebuild the page under it.
  final _inFlight = ValueNotifier(false);

  /// A list that stops notifying without ever ending — one disposed
  /// mid-gesture, which is what a photo dragged off the screen does to the
  /// page under it — would otherwise leave the app untappable. Any silence
  /// this long means the motion is over, whatever the notifications said.
  ///
  /// Short, because this is a dead zone: taps land on nothing until it
  /// expires. A list that is actually moving notifies every frame, so a
  /// third of a second of silence is not a pause in a fling — it is a
  /// scroll view that has gone away.
  static const _staleAfter = Duration(milliseconds: 350);

  /// Checks for silence twice per [_staleAfter], so a moving list costs a
  /// flag per frame rather than a new timer per frame.
  Timer? _watchdog;
  bool _heard = false;
  int _silentChecks = 0;

  @override
  void dispose() {
    _watchdog?.cancel();
    _inFlight.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      // Only motion the user threw. A programmatic scroll — the grid
      // opening on the newest photo — is not something to brake.
      if (notification.dragDetails != null) _arm(true);
    } else if (notification is ScrollEndNotification) {
      _arm(false);
    } else if (_inFlight.value) {
      _heard = true;
    }
    return false;
  }

  void _arm(bool value) {
    _watchdog?.cancel();
    _heard = false;
    _silentChecks = 0;
    _watchdog = value
        ? Timer.periodic(_staleAfter ~/ 2, (_) => _check())
        : null;
    _inFlight.value = value;
  }

  /// Stale after two silent checks: 350-525 ms with no notification.
  void _check() {
    if (_heard) {
      _heard = false;
      _silentChecks = 0;
    } else if (++_silentChecks >= 2) {
      _arm(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          widget.child,
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: _inFlight,
              builder: (context, inFlight, _) => IgnorePointer(
                ignoring: !inFlight,
                child: GestureDetector(
                  // Translucent, so the same touch still reaches the list
                  // and stops it; on top, so the tap resolves here rather
                  // than on the row. No long-press: holding still then
                  // dragging has to keep scrolling the page.
                  behavior: HitTestBehavior.translucent,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
