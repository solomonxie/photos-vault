import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_detail.dart';

/// One event: what kind, when, tags, notes.
///
/// Returns the edited event, or `null` if the sheet was dismissed. Nothing is
/// written here — the caller decides which passcode it belongs to.
///
/// The type cannot be changed on "First met / knew at": there is exactly one
/// per profile and it is the row the section is anchored on. Everything else
/// can be anything.
Future<PersonEvent?> showPersonEventSheet(
  BuildContext context, {
  required PersonEvent event,
}) => showCupertinoModalPopup<PersonEvent>(
  context: context,
  builder: (sheetContext) => _PersonEventSheet(event: event),
);

class _PersonEventSheet extends StatefulWidget {
  const _PersonEventSheet({required this.event});

  final PersonEvent event;

  @override
  State<_PersonEventSheet> createState() => _PersonEventSheetState();
}

class _PersonEventSheetState extends State<_PersonEventSheet> {
  /// Seeded with the date the wheel is already showing, so Save records what
  /// the reader is looking at. Left null it would save "not set" under a
  /// visible date, which is the sort of thing nobody notices until the row is
  /// wrong. Cancelling still writes nothing at all.
  late PersonEvent _event = widget.event.at == null
      ? widget.event.copyWith(at: DateTime.now)
      : widget.event;
  late final TextEditingController _tags = TextEditingController(
    text: _event.tags.join(', '),
  );
  late final TextEditingController _notes = TextEditingController(
    text: _event.notes,
  );

  @override
  void dispose() {
    _tags.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _event.isFirstMet ? l10n.eventsFirstMet : l10n.eventsAddButton,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: CupertinoColors.white,
                ),
              ),
              const SizedBox(height: 12),
              if (!_event.isFirstMet) _typeRow(l10n),
              _dateRow(l10n),
              const SizedBox(height: 8),
              _field(_tags, l10n.eventsTagsPlaceholder),
              const SizedBox(height: 8),
              _field(_notes, l10n.eventsNotesLabel),
              const SizedBox(height: 14),
              CupertinoButton.filled(
                onPressed: () => Navigator.of(context).pop(
                  _event.copyWith(
                    tags: [
                      for (final tag in _tags.text.split(','))
                        if (tag.trim().isNotEmpty) tag.trim(),
                    ],
                    notes: _notes.text.trim(),
                  ),
                ),
                child: Text(l10n.settingsSaveButton),
              ),
              CupertinoButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.actionCancel),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typeRow(AppLocalizations l10n) => CupertinoButton(
    padding: EdgeInsets.zero,
    onPressed: () async {
      final picked = await showCupertinoModalPopup<PersonEventType>(
        context: context,
        builder: (pickerContext) => CupertinoActionSheet(
          title: Text(l10n.eventsTypeLabel),
          actions: [
            for (final type in PersonEventType.values)
              // Reserved for the one row that always exists.
              if (type != PersonEventType.firstMet)
                CupertinoActionSheetAction(
                  onPressed: () => Navigator.of(pickerContext).pop(type),
                  child: Text(eventTypeLabel(l10n, type)),
                ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(pickerContext).pop(),
            child: Text(l10n.actionCancel),
          ),
        ),
      );
      if (picked != null) {
        setState(() => _event = _event.copyWith(type: picked));
      }
    },
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          l10n.eventsTypeLabel,
          style: const TextStyle(color: CupertinoColors.systemGrey),
        ),
        Text(
          eventTypeLabel(l10n, _event.type),
          style: const TextStyle(color: CupertinoColors.white),
        ),
      ],
    ),
  );

  /// A wheel, inline rather than behind another sheet: the date is the one
  /// thing every event has, and the commonest edit is nudging it.
  Widget _dateRow(AppLocalizations l10n) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              l10n.eventsDateLabel,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
            Text(
              DateFormat.yMMMd().format(_event.at!),
              style: const TextStyle(color: CupertinoColors.white),
            ),
          ],
        ),
      ),
      SizedBox(
        height: 160,
        child: CupertinoDatePicker(
          mode: CupertinoDatePickerMode.date,
          initialDateTime: _event.at ?? DateTime.now(),
          maximumDate: DateTime.now(),
          onDateTimeChanged: (value) =>
              setState(() => _event = _event.copyWith(at: () => value)),
        ),
      ),
    ],
  );

  Widget _field(TextEditingController controller, String placeholder) =>
      CupertinoTextField(
        controller: controller,
        placeholder: placeholder,
        padding: const EdgeInsets.all(10),
        style: const TextStyle(color: CupertinoColors.white),
      );
}

String eventTypeLabel(AppLocalizations l10n, PersonEventType type) =>
    switch (type) {
      PersonEventType.firstMet => l10n.eventTypeFirstMet,
      PersonEventType.reunion => l10n.eventTypeReunion,
      PersonEventType.trip => l10n.eventTypeTrip,
      PersonEventType.celebration => l10n.eventTypeCelebration,
      PersonEventType.milestone => l10n.eventTypeMilestone,
      PersonEventType.favour => l10n.eventTypeFavour,
      PersonEventType.fallingOut => l10n.eventTypeFallingOut,
      PersonEventType.other => l10n.eventTypeOther,
    };
