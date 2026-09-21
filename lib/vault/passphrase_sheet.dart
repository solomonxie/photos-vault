import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import 'keys.dart';

/// One prompt, and it never says no.
///
/// No "new or existing" fork: whatever is typed becomes the active
/// passphrase, and if it happens to be one used before, that generation's
/// carriers simply start opening. A screen that can answer "wrong" is a
/// screen that confirms there is something to be wrong about — the same
/// reason the 4-digit gate has no error state.
Future<PassphraseEntry?> showVaultSetupSheet(
  BuildContext context, {
  required VaultKeys keys,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final passphrase = TextEditingController();
  final hint = TextEditingController();
  var error = false;

  final entry = await showCupertinoModalPopup<PassphraseEntry>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Container(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.vaultSetupTitle,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: CupertinoColors.white,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.vaultSetupBody,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: CupertinoColors.systemGrey,
              ),
            ),
            const SizedBox(height: 18),
            CupertinoTextField(
              controller: passphrase,
              autofocus: true,
              obscureText: true,
              placeholder: l10n.vaultSetupPassphraseLabel,
              padding: const EdgeInsets.all(12),
            ),
            if (error) ...[
              const SizedBox(height: 8),
              Text(
                l10n.vaultSetupTooShort(minimumPassphraseLength),
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.systemRed,
                ),
              ),
            ],
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: hint,
              placeholder: l10n.vaultSetupHintLabel,
              padding: const EdgeInsets.all(12),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.vaultSetupHintNote,
              style: const TextStyle(
                fontSize: 12,
                height: 1.4,
                color: CupertinoColors.systemGrey,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.vaultSetupWarning,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: CupertinoColors.systemGrey,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: CupertinoButton.filled(
                onPressed: () async {
                  final typed = passphrase.text;
                  if (typed.length < minimumPassphraseLength) {
                    setState(() => error = true);
                    return;
                  }
                  final added = await keys.add(typed, hint: hint.text.trim());
                  if (context.mounted) Navigator.of(context).pop(added);
                },
                child: Text(l10n.vaultSetupContinue),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  passphrase.dispose();
  hint.dispose();
  return entry;
}

/// Adding an older passphrase, from inside an unlocked album. This one
/// *may* say wrong: it is the recovery secret, not the gate, and somebody
/// restoring a phone needs to know whether they typed it right.
Future<bool> showAddPassphraseSheet(
  BuildContext context, {
  required VaultKeys keys,
  required List<PassphraseEntry> candidates,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final passphrase = TextEditingController();
  var wrong = false;

  final added = await showCupertinoModalPopup<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Container(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.vaultAddPassphraseTitle,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: CupertinoColors.white,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.vaultAddPassphraseBody,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: CupertinoColors.systemGrey,
              ),
            ),
            for (final candidate in candidates) ...[
              const SizedBox(height: 6),
              Text(
                candidate.hint.isEmpty
                    ? l10n.vaultPassphraseNoHint
                    : l10n.vaultPassphraseHint(candidate.hint),
                style: const TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.systemGrey2,
                ),
              ),
            ],
            const SizedBox(height: 18),
            CupertinoTextField(
              controller: passphrase,
              autofocus: true,
              obscureText: true,
              placeholder: l10n.vaultSetupPassphraseLabel,
              padding: const EdgeInsets.all(12),
            ),
            if (wrong) ...[
              const SizedBox(height: 8),
              Text(
                l10n.vaultPassphraseWrong,
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.systemRed,
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: CupertinoButton.filled(
                onPressed: () async {
                  for (final candidate in candidates) {
                    if (await keys.unlockEntry(candidate, passphrase.text)) {
                      if (context.mounted) Navigator.of(context).pop(true);
                      return;
                    }
                  }
                  setState(() => wrong = true);
                },
                child: Text(l10n.vaultSetupContinue),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  passphrase.dispose();
  return added ?? false;
}
