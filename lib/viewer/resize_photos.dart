import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/smaller_export.dart';
import '../storage/asset_record.dart';

/// Past this, "Save as New" is off: a copy of every one is a library of
/// duplicates.
const resizeNewCopyLimit = 10;

enum SaveMode { replace, copy }

/// What every edit asks once it has a result: replace the original (to
/// Recently Deleted, still recoverable) or keep both. Null: discard.
Future<SaveMode?> askSaveMode(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showCupertinoModalPopup<SaveMode>(
    context: context,
    builder: (sheetContext) => CupertinoActionSheet(
      actions: [
        CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(sheetContext).pop(SaveMode.replace),
          child: Text(l10n.resizeReplace(1)),
        ),
        CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(SaveMode.copy),
          child: Text(l10n.resizeSaveNew),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(sheetContext).pop(),
        child: Text(l10n.editDiscard),
      ),
    ),
  );
}

/// Size and mode in one sheet, then the resize. Every result is a new
/// library item; [SaveMode.replace] then hands the originals that made it
/// to [replaceOriginals] (Recently Deleted, so still recoverable). Returns
/// the new records.
///
/// [replaceNote] overrides the sheet's explanation where a replaced
/// original goes somewhere other than Recently Deleted.
Future<List<AssetRecord>> resizePhotos<T>(
  BuildContext context, {
  required List<T> records,
  required Future<Uint8List?> Function(T record) readBytes,
  required Future<AssetRecord> Function(
    T source,
    Uint8List bytes,
    String extension,
  )
  saveCopy,
  required Future<void> Function(List<T> originals) replaceOriginals,
  String? replaceNote,
}) async {
  if (records.isEmpty) return const [];
  final l10n = AppLocalizations.of(context)!;
  final choice = await showCupertinoModalPopup<(ExportSize, SaveMode)>(
    context: context,
    builder: (_) => _ResizeSheet(count: records.length, note: replaceNote),
  );
  if (choice == null) return const [];
  final (size, mode) = choice;

  final created = <AssetRecord>[];
  final done = <T>[];
  for (final record in records) {
    final bytes = await readBytes(record);
    final small = bytes == null ? null : await shrinkPhoto(bytes, size);
    if (small == null) continue;
    try {
      created.add(await saveCopy(record, small.bytes, small.extension));
      done.add(record);
    } catch (_) {
      // Left as it is; counted as skipped below.
    }
  }
  if (!context.mounted) return created;
  if (done.isEmpty) {
    await _tell(context, l10n.resizeFailed);
    return created;
  }
  if (mode == SaveMode.replace) await replaceOriginals(done);
  if (!context.mounted) return created;
  final skipped = records.length - done.length;
  if (skipped > 0) await _tell(context, l10n.exportSmallerSkipped(skipped));
  return created;
}

class _ResizeSheet extends StatefulWidget {
  const _ResizeSheet({required this.count, this.note});

  final int count;
  final String? note;

  @override
  State<_ResizeSheet> createState() => _ResizeSheetState();
}

class _ResizeSheetState extends State<_ResizeSheet> {
  ExportSize _size = ExportSize.original;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final copyAllowed = widget.count <= resizeNewCopyLimit;
    void pick(SaveMode mode) => Navigator.of(context).pop((_size, mode));

    return CupertinoActionSheet(
      title: Text(l10n.resizeTitle(widget.count)),
      message: Column(
        children: [
          Text(widget.note ?? l10n.resizeBody),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<ExportSize>(
              groupValue: _size,
              onValueChanged: (size) {
                if (size != null) setState(() => _size = size);
              },
              children: {
                for (final size in ExportSize.values)
                  size: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(switch (size) {
                      ExportSize.original => l10n.resizeSameSize,
                      ExportSize.large => l10n.exportSmallerLarge(
                        size.maxEdge!,
                      ),
                      ExportSize.medium => l10n.exportSmallerMedium(
                        size.maxEdge!,
                      ),
                      ExportSize.small => l10n.exportSmallerSmall(
                        size.maxEdge!,
                      ),
                    }, style: const TextStyle(fontSize: 12)),
                  ),
              },
            ),
          ),
          if (!copyAllowed) ...[
            const SizedBox(height: 10),
            Text(l10n.resizeCopyLimit(resizeNewCopyLimit)),
          ],
        ],
      ),
      actions: [
        CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => pick(SaveMode.replace),
          child: Text(l10n.resizeReplace(widget.count)),
        ),
        CupertinoActionSheetAction(
          // An action sheet button can't be disabled; this one just
          // doesn't answer, and says why above.
          onPressed: copyAllowed ? () => pick(SaveMode.copy) : () {},
          child: Text(
            l10n.resizeSaveNew,
            style: copyAllowed
                ? null
                : const TextStyle(color: CupertinoColors.systemGrey),
          ),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.actionCancel),
      ),
    );
  }
}

Future<void> _tell(BuildContext context, String message) =>
    showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(AppLocalizations.of(context)!.actionOk),
          ),
        ],
      ),
    );
