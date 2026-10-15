import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import 'bucket.dart';
import 'keys.dart';

/// One prompt, and it never says no.
///
/// No "new or existing" fork: whatever is typed is first tried against
/// every entry this phone and the buckets' `index.bin` know, so one used
/// before lands on its old salt and that generation's carriers open. Only
/// a passphrase matching none becomes a new entry. A screen that can
/// answer "wrong" is a screen that confirms there is something to be wrong
/// about — the same reason the 4-digit gate has no error state.
Future<PassphraseEntry?> showVaultSetupSheet(
  BuildContext context, {
  required VaultKeys keys,
  VaultBucket? bucket,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final passphrase = TextEditingController();
  final hint = TextEditingController();
  final vaultBucket = bucket ?? VaultBucket();
  // Asked while the user types.
  final known = vaultBucket.knownPassphrases().catchError(
    (Object _) => const <PassphraseEntry>[],
  );
  var error = false;
  var busy = false;

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
                onPressed: busy
                    ? null
                    : () async {
                        final typed = passphrase.text;
                        if (typed.length < minimumPassphraseLength) {
                          setState(() => error = true);
                          return;
                        }
                        setState(() => busy = true);
                        final entry = await keys.setUp(
                          typed,
                          hint: hint.text.trim(),
                          // A stalled bucket must not hang the sheet.
                          known: await known.timeout(
                            const Duration(seconds: 20),
                            onTimeout: () => const [],
                          ),
                        );
                        unawaited(
                          keys.entries().then(vaultBucket.ensurePublished),
                        );
                        if (context.mounted) Navigator.of(context).pop(entry);
                      },
                child: busy
                    ? const CupertinoActivityIndicator()
                    : Text(l10n.vaultSetupContinue),
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
  VaultBucket? bucket,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final passphrase = TextEditingController();
  var wrong = false;
  var busy = false;

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
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        for (final candidate in candidates) {
                          if (await keys.unlockEntry(
                            candidate,
                            passphrase.text,
                          )) {
                            unawaited(
                              keys.entries().then(
                                (bucket ?? VaultBucket()).ensurePublished,
                              ),
                            );
                            if (context.mounted) {
                              Navigator.of(context).pop(true);
                            }
                            return;
                          }
                        }
                        if (context.mounted) {
                          setState(() {
                            busy = false;
                            wrong = true;
                          });
                        }
                      },
                child: busy
                    ? const CupertinoActivityIndicator()
                    : Text(l10n.vaultSetupContinue),
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
