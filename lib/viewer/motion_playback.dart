import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record_store.dart';

/// How a moving picture — a Live Photo, a GIF — behaves in the viewer.
///
/// One setting for both, because the question is the same one and having
/// it answered differently per kind means learning it twice.
enum MotionPlayMode {
  /// Photos' own behaviour: a still until you press and hold it.
  hold,

  /// Runs on its own, over and over, for as long as it's on screen.
  loop,

  /// Frozen. What you want when the animation is the distraction rather
  /// than the point — reading the text in a screen recording, say.
  still,
}

/// The chosen mode, remembered across photos and across launches.
///
/// Persisted in app state rather than per photo: "how should GIFs behave"
/// is a preference about *you*, not about any one picture, and a per-photo
/// switch would ask the same question a thousand times.
class MotionPlaybackSetting {
  MotionPlaybackSetting({required this.settings});

  final AssetRecordStore settings;

  static const key = 'motion_play_mode_v1';

  final ValueNotifier<MotionPlayMode> mode = ValueNotifier(MotionPlayMode.hold);

  Future<void> load() async {
    try {
      final stored = await settings.getAppState(key);
      mode.value = MotionPlayMode.values.firstWhere(
        (m) => m.name == stored,
        orElse: () => MotionPlayMode.hold,
      );
    } catch (_) {
      // No database (tests, no platform channel) — hold is the default
      // and a working viewer, which is what matters.
    }
  }

  Future<void> set(MotionPlayMode value) async {
    mode.value = value;
    try {
      await settings.setAppState(key, value.name);
    } catch (_) {
      // See [load]. The choice still applies to this session.
    }
  }

  void dispose() => mode.dispose();
}

/// Three icons in a pill: hold, loop, freeze. Shown over the picture
/// itself, beside the LIVE/GIF badge.
///
/// Icons rather than a menu, because the whole set fits in the space one
/// menu button would take and the current answer is then visible without
/// opening anything — which matters for a control whose *effect* is only
/// obvious while you watch the picture behind it.
class MotionPlayModeBar extends StatelessWidget {
  const MotionPlayModeBar({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final MotionPlayMode mode;
  final ValueChanged<MotionPlayMode> onChanged;

  static IconData iconOf(MotionPlayMode mode) => switch (mode) {
    MotionPlayMode.hold => CupertinoIcons.hand_draw_fill,
    MotionPlayMode.loop => CupertinoIcons.arrow_2_circlepath,
    MotionPlayMode.still => CupertinoIcons.pause_fill,
  };

  static String labelOf(AppLocalizations l10n, MotionPlayMode mode) =>
      switch (mode) {
        MotionPlayMode.hold => l10n.motionPlayHold,
        MotionPlayMode.loop => l10n.motionPlayLoop,
        MotionPlayMode.still => l10n.motionPlayStill,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0x8C000000),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in MotionPlayMode.values)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(value),
              child: Container(
                width: 32,
                height: 26,
                decoration: BoxDecoration(
                  color: value == mode
                      ? const Color(0xE6FFFFFF)
                      : const Color(0x00000000),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  iconOf(value),
                  size: 14,
                  semanticLabel: labelOf(l10n, value),
                  color: value == mode
                      ? CupertinoColors.black
                      : CupertinoColors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The little `LIVE` / `GIF` label over the top-left of a moving picture.
class MotionBadge extends StatelessWidget {
  const MotionBadge({
    super.key,
    required this.label,
    required this.icon,
    required this.active,
  });

  final String label;
  final IconData icon;

  /// Lit while it's actually moving — the badge doubles as the answer to
  /// "is this playing?", which a static label can't give.
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: active ? const Color(0xE6FFFFFF) : const Color(0x8C000000),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color: active ? CupertinoColors.black : CupertinoColors.white,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? CupertinoColors.black : CupertinoColors.white,
          ),
        ),
      ],
    ),
  );
}
