import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

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
///
/// The cover is [PrivacyShield], over the whole navigator, not over this
/// screen: a photo opened from the album, a sheet or a context menu sits
/// above the album's own route, and a cover there left exactly those in the
/// app-switcher snapshot. Natively too (`PrivacyCoverChannel.swift`),
/// because the snapshot can be taken before Flutter paints another frame.
mixin PrivateScreenLifecycle<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PrivacyShield.open.value++;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PrivacyShield.open.value--;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    // Everything above the library, including a photo opened from here —
    // popping only this screen would leave the one photo somebody was
    // looking at on screen.
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// Kept for the screens that call it; the cover itself is [PrivacyShield].
  Widget withPrivacyCover(Widget child) => child;
}

/// An opaque cover over everything while a private screen is open and the
/// app is not frontmost. Opaque, not blurred: a blur of a photo is still a
/// photo.
class PrivacyShield extends StatefulWidget {
  const PrivacyShield({super.key, required this.child});

  final Widget child;

  /// How many private screens are mounted.
  static final ValueNotifier<int> open = ValueNotifier(0);

  static const _channel = MethodChannel('byo.photos/privacy_cover');

  @override
  State<PrivacyShield> createState() => _PrivacyShieldState();
}

class _PrivacyShieldState extends State<PrivacyShield>
    with WidgetsBindingObserver {
  bool _away = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PrivacyShield.open.addListener(_onOpenChanged);
  }

  @override
  void dispose() {
    PrivacyShield.open.removeListener(_onOpenChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onOpenChanged() {
    final open = PrivacyShield.open.value > 0;
    PrivacyShield._channel
        .invokeMethod<void>('setCovering', open)
        .catchError((Object _) {});
    // Changes while a route builds or unmounts; repaint after it.
    if (!_away) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final away = state != AppLifecycleState.resumed;
    if (away != _away && mounted) setState(() => _away = away);
  }

  @override
  Widget build(BuildContext context) => Stack(
    textDirection: TextDirection.ltr,
    children: [
      widget.child,
      if (_away && PrivacyShield.open.value > 0)
        const Positioned.fill(
          child: ColoredBox(
            key: ValueKey('privacyCover'),
            color: CupertinoColors.black,
          ),
        ),
    ],
  );
}
