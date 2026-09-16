import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

/// Result of [showSetPasscodeSheet] — an arbitrary-length passcode (unlike
/// Private Albums' strict 4 digits) plus an optional hint shown back at
/// unlock time.
class SetPasscodeResult {
  const SetPasscodeResult({required this.passcode, required this.hint});

  final String passcode;
  final String hint;
}

/// Person-profile lock (T7.4): choose any passcode + an optional hint.
Future<SetPasscodeResult?> showSetPasscodeSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  final passcodeController = TextEditingController();
  final hintController = TextEditingController();
  return showCupertinoDialog<SetPasscodeResult>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final valid = passcodeController.text.isNotEmpty;
        return CupertinoAlertDialog(
          title: Text(l10n.personProfileSetPasscodeTitle),
          content: Column(
            children: [
              const SizedBox(height: 8),
              Text(l10n.personProfileSetPasscodeBody),
              const SizedBox(height: 8),
              CupertinoTextField(
                controller: passcodeController,
                autofocus: true,
                obscureText: true,
                placeholder: l10n.personProfilePasscodeLabel,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              CupertinoTextField(
                controller: hintController,
                placeholder: l10n.personProfileHintLabel,
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.actionCancel),
            ),
            CupertinoDialogAction(
              onPressed: valid
                  ? () => Navigator.of(context).pop(
                      SetPasscodeResult(
                        passcode: passcodeController.text,
                        hint: hintController.text,
                      ),
                    )
                  : null,
              child: Text(l10n.personProfileLockButton),
            ),
          ],
        );
      },
    ),
  );
}

/// Unlocking a locked profile: shows [hint] if present, returns whatever the
/// user typed (the caller hashes and compares — no distinct "wrong
/// passcode" UI here either, just re-prompting via [personProfileWrongPasscode]).
Future<String?> showEnterPasscodeSheet(BuildContext context, {String? hint}) {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController();
  return showCupertinoDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final valid = controller.text.isNotEmpty;
        return CupertinoAlertDialog(
          title: Text(l10n.personProfileUnlockTitle),
          content: Column(
            children: [
              if (hint != null && hint.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(l10n.personProfileHintPrefix(hint)),
              ],
              const SizedBox(height: 8),
              CupertinoTextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                placeholder: l10n.personProfilePasscodeLabel,
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.actionCancel),
            ),
            CupertinoDialogAction(
              onPressed: valid
                  ? () => Navigator.of(context).pop(controller.text)
                  : null,
              child: Text(l10n.personProfileUnlockButton),
            ),
          ],
        );
      },
    ),
  );
}
