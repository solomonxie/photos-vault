import 'package:flutter/cupertino.dart';

/// Leaves the private album when the app does.
///
/// Switch apps, lock the phone, or hand it over with the album open, and
/// coming back should land on the library — not on the photos somebody
/// typed a code to see. The code is cheap to type again; a private album
/// sitting open in a handed-over phone is not recoverable.
///
/// Two different moments, because iOS has two:
///
/// - **inactive** — a control-centre swipe, a notification banner, an
///   incoming call, *and* the system's own prompts (the delete
///   confirmation hiding puts up). Too ordinary to throw the screen away
///   for, but it is also the moment before the app-switcher snapshot is
///   taken, so the album is covered. Coming straight back uncovers it.
/// - **paused** — actually backgrounded. Now the album goes.
///
/// Covering rather than popping on `inactive` is what keeps the hide flow
/// working: the OS delete prompt makes the app inactive, and an album that
/// popped itself at that moment would take the half-finished hide with it.
mixin PrivateScreenLifecycle<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        if (!_covered && mounted) setState(() => _covered = true);
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Everything above the library, including a photo opened from
        // here — popping only this screen would leave the one photo
        // somebody was looking at on screen.
        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      case AppLifecycleState.resumed:
        if (_covered && mounted) setState(() => _covered = false);
    }
  }

  /// [child] with an opaque cover over it while the app is not frontmost.
  /// Opaque, not blurred: a blur of a photo is still a photo.
  Widget withPrivacyCover(Widget child) => Stack(
    children: [
      child,
      if (_covered)
        const Positioned.fill(child: ColoredBox(color: CupertinoColors.black)),
    ],
  );
}
