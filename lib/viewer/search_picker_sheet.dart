import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

const _sheetBackground = Color(0xFF1C1C1E);
const _fieldBackground = Color(0xFF2C2C2E);

/// Searchable drop-down over [options] — the sheet stays on top of the page
/// that opened it, so picking a location/tag/school never costs a full page
/// push. Pops with the chosen option, the typed value, `''` when cleared, or
/// `null` when dismissed.
Future<String?> showSearchPickerSheet({
  required BuildContext context,
  required String title,
  required Set<String> options,
  String? selected,
  String? clearLabel,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showSearchPickerSheetOf<String>(
    context: context,
    title: title,
    options: options.toList()..sort(),
    labelOf: (o) => o,
    isSelected: (o) => o == selected,
    clearLabel: clearLabel,
    clearValue: '',
    createLabel: (query) =>
        query.isEmpty ||
            options.any((o) => o.toLowerCase() == query.toLowerCase())
        ? null
        : l10n.stringPickerUseValue(query),
    onCreate: (query) async => query,
  );
}

/// Same drop-down for non-string entities (people). [createLabel] returns
/// `null` to hide the create row for the current query, and is required
/// whenever [onCreate] is given.
Future<T?> showSearchPickerSheetOf<T>({
  required BuildContext context,
  required String title,
  required List<T> options,
  required String Function(T) labelOf,
  bool Function(T)? isSelected,
  String? clearLabel,
  T? clearValue,
  String? Function(String query)? createLabel,
  Future<T?> Function(String query)? onCreate,
}) {
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (_) => _SearchPickerSheet<T>(
      title: title,
      options: options,
      labelOf: labelOf,
      isSelected: isSelected,
      clearLabel: clearLabel,
      clearValue: clearValue,
      createLabel: createLabel,
      onCreate: onCreate,
    ),
  );
}

class _SearchPickerSheet<T> extends StatefulWidget {
  const _SearchPickerSheet({
    required this.title,
    required this.options,
    required this.labelOf,
    this.isSelected,
    this.clearLabel,
    this.clearValue,
    this.createLabel,
    this.onCreate,
  });

  final String title;
  final List<T> options;
  final String Function(T) labelOf;
  final bool Function(T)? isSelected;
  final String? clearLabel;
  final T? clearValue;
  final String? Function(String query)? createLabel;
  final Future<T?> Function(String query)? onCreate;

  @override
  State<_SearchPickerSheet<T>> createState() => _SearchPickerSheetState<T>();
}

class _SearchPickerSheetState<T> extends State<_SearchPickerSheet<T>> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _create(String query) async {
    final created = await widget.onCreate!(query);
    if (created != null && mounted) Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final media = MediaQuery.of(context);
    final query = _query.trim();
    final matches = widget.options
        .where(
          (o) => widget.labelOf(o).toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    final createLabel = widget.onCreate == null
        ? null
        : widget.createLabel!(query);

    // Sit right above the keyboard, and never taller than what's left.
    final available =
        media.size.height - media.viewInsets.bottom - media.padding.top - 24;
    final height = math.min(available, media.size.height * 0.55);

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        height: height,
        decoration: const BoxDecoration(
          color: _sheetBackground,
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: CupertinoSearchTextField(
                  controller: _controller,
                  autofocus: true,
                  backgroundColor: _fieldBackground,
                  style: const TextStyle(color: CupertinoColors.white),
                  onChanged: (v) => setState(() => _query = v),
                  onSubmitted: (v) {
                    if (widget.onCreate != null && v.trim().isNotEmpty) {
                      _create(v.trim());
                    }
                  },
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  children: [
                    if (createLabel != null)
                      _PickerRow(
                        label: createLabel,
                        leading: CupertinoIcons.add_circled,
                        onTap: () => _create(query),
                      ),
                    for (final option in matches)
                      _PickerRow(
                        label: widget.labelOf(option),
                        selected: widget.isSelected?.call(option) ?? false,
                        onTap: () => Navigator.of(context).pop(option),
                      ),
                    if (widget.clearLabel != null)
                      _PickerRow(
                        label: widget.clearLabel!,
                        leading: CupertinoIcons.clear_circled,
                        muted: true,
                        onTap: () =>
                            Navigator.of(context).pop(widget.clearValue),
                      ),
                    if (matches.isEmpty && createLabel == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 24,
                        ),
                        child: Text(
                          l10n.stringPickerTypeToCreate,
                          style: const TextStyle(
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.label,
    required this.onTap,
    this.leading,
    this.selected = false,
    this.muted = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? leading;
  final bool selected;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final color = muted ? CupertinoColors.systemGrey : CupertinoColors.white;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF2C2C2E))),
        ),
        child: Row(
          children: [
            if (leading != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  leading,
                  size: 20,
                  color: CupertinoColors.activeBlue,
                ),
              ),
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: color, fontSize: 15),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (selected)
              const Icon(
                CupertinoIcons.check_mark,
                size: 18,
                color: CupertinoColors.activeBlue,
              ),
          ],
        ),
      ),
    );
  }
}
