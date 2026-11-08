import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

/// A photo's date and time: a date wheel with a year, then a time wheel.
/// `dateAndTime` mode has no year column, so a photo from another year
/// couldn't be set. Null when cancelled.
Future<DateTime?> showDateTimeSheet(
  BuildContext context, {
  required DateTime initial,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final now = DateTime.now();
  final start = initial.isAfter(now) ? now : initial;
  var day = DateTime(start.year, start.month, start.day);
  var time = start;
  final saved = await showCupertinoModalPopup<bool>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      title: Text(l10n.detailEditDateTimeTitle),
      message: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 180,
            child: CupertinoDatePicker(
              key: const ValueKey('dateTimeSheetDate'),
              mode: CupertinoDatePickerMode.date,
              initialDateTime: day,
              minimumYear: 1800,
              maximumDate: now,
              onDateTimeChanged: (v) => day = v,
            ),
          ),
          SizedBox(
            height: 140,
            child: CupertinoDatePicker(
              key: const ValueKey('dateTimeSheetTime'),
              mode: CupertinoDatePickerMode.time,
              initialDateTime: time,
              onDateTimeChanged: (v) => time = v,
            ),
          ),
        ],
      ),
      actions: [
        CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.settingsSaveButton),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(l10n.actionCancel),
      ),
    ),
  );
  if (saved != true) return null;
  final picked = DateTime(
    day.year,
    day.month,
    day.day,
    time.hour,
    time.minute,
    start.second,
  );
  return picked.isAfter(now) ? now : picked;
}
