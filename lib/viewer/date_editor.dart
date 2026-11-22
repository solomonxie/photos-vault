import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';

/// A likely date for the photo, offered as one tap.
typedef DateGuess = ({String label, DateTime date});

/// Changes one photo's date, or many: typed, not spun on wheels, with the
/// likely dates offered first. Many photos can all be set to one date or
/// all shifted by the same amount, which keeps their order. Returns what to
/// do to each photo's date; null when cancelled.
Future<DateTime Function(DateTime)?> showDateEditor(
  BuildContext context, {
  required DateTime initial,
  int count = 1,
  List<DateGuess> guesses = const [],
}) => Navigator.of(context).push(
  CupertinoPageRoute<DateTime Function(DateTime)>(
    fullscreenDialog: true,
    builder: (_) =>
        _DateEditor(initial: initial.toLocal(), count: count, guesses: guesses),
  ),
);

/// [at] moved by whole calendar months, the day kept where the month has it.
DateTime shiftDate(
  DateTime at, {
  int years = 0,
  int months = 0,
  int days = 0,
  int hours = 0,
}) {
  final total = at.month - 1 + years * 12 + months;
  final year = at.year + (total / 12).floor();
  final month = total % 12 + 1;
  final last = DateTime(year, month + 1, 0).day;
  return DateTime(
    year,
    month,
    at.day > last ? last : at.day,
    at.hour,
    at.minute,
    at.second,
  ).add(Duration(days: days, hours: hours));
}

enum _Mode { set, shift }

class _DateEditor extends StatefulWidget {
  const _DateEditor({
    required this.initial,
    required this.count,
    required this.guesses,
  });

  final DateTime initial;
  final int count;
  final List<DateGuess> guesses;

  @override
  State<_DateEditor> createState() => _DateEditorState();
}

class _DateEditorState extends State<_DateEditor> {
  var _mode = _Mode.set;
  var _later = false;

  late final _year = _field(widget.initial.year);
  late final _month = _field(widget.initial.month);
  late final _day = _field(widget.initial.day);
  late final _hour = _field(widget.initial.hour);
  late final _minute = _field(widget.initial.minute);

  final _years = TextEditingController();
  final _months = TextEditingController();
  final _days = TextEditingController();
  final _hours = TextEditingController();

  TextEditingController _field(int v) =>
      TextEditingController(text: v.toString().padLeft(2, '0'));

  @override
  void dispose() {
    for (final c in [
      _year,
      _month,
      _day,
      _hour,
      _minute,
      _years,
      _months,
      _days,
      _hours,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _int(TextEditingController c) => int.tryParse(c.text.trim());

  /// The typed date, or null when it isn't one (30 Feb, month 13).
  DateTime? get _typed {
    final y = _int(_year), mo = _int(_month), d = _int(_day);
    final h = _int(_hour) ?? 0, mi = _int(_minute) ?? 0;
    if (y == null || mo == null || d == null) return null;
    if (y < 1800 || mo < 1 || mo > 12 || h > 23 || mi > 59) return null;
    final at = DateTime(y, mo, d, h, mi, widget.initial.second);
    if (at.month != mo || at.day != d) return null;
    return at.isAfter(DateTime.now()) ? null : at;
  }

  DateTime Function(DateTime)? get _result {
    if (_mode == _Mode.set) {
      final at = _typed;
      return at == null ? null : (_) => at;
    }
    final sign = _later ? 1 : -1;
    int n(TextEditingController c) => (_int(c) ?? 0) * sign;
    final years = n(_years), months = n(_months);
    final days = n(_days), hours = n(_hours);
    if (years == 0 && months == 0 && days == 0 && hours == 0) return null;
    return (at) => shiftDate(
      at.toLocal(),
      years: years,
      months: months,
      days: days,
      hours: hours,
    );
  }

  void _use(DateTime d) => setState(() {
    _mode = _Mode.set;
    _year.text = '${d.year}';
    _month.text = d.month.toString().padLeft(2, '0');
    _day.text = d.day.toString().padLeft(2, '0');
    _hour.text = d.hour.toString().padLeft(2, '0');
    _minute.text = d.minute.toString().padLeft(2, '0');
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final result = _result;
    final preview = result?.call(widget.initial);
    final format = DateFormat.yMMMMEEEEd().add_jm();
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
        middle: Text(
          widget.count == 1
              ? l10n.detailEditDateTimeTitle
              : l10n.dateEditManyTitle(widget.count),
        ),
        trailing: CupertinoButton(
          key: const ValueKey('dateEditSave'),
          padding: EdgeInsets.zero,
          onPressed: result == null
              ? null
              : () => Navigator.of(context).pop(result),
          child: Text(
            l10n.settingsSaveButton,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Text(
              format.format(widget.initial),
              style: const TextStyle(
                fontSize: 15,
                color: CupertinoColors.systemGrey,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              preview == null ? l10n.dateEditNotADate : format.format(preview),
              key: const ValueKey('dateEditPreview'),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: preview == null
                    ? CupertinoColors.systemRed
                    : CupertinoColors.white,
              ),
            ),
            if (widget.count > 1)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: CupertinoSlidingSegmentedControl<_Mode>(
                  groupValue: _mode,
                  onValueChanged: (m) => setState(() => _mode = m ?? _mode),
                  children: {
                    _Mode.set: Text(l10n.dateEditSetAll),
                    _Mode.shift: Text(l10n.dateEditShiftAll),
                  },
                ),
              ),
            const SizedBox(height: 20),
            if (_mode == _Mode.set)
              ..._setFields(l10n)
            else
              ..._shiftFields(l10n),
            if (widget.guesses.isNotEmpty) ...[
              const SizedBox(height: 28),
              Text(
                l10n.dateEditSuggested.toUpperCase(),
                style: const TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.systemGrey,
                ),
              ),
              const SizedBox(height: 6),
              for (final g in widget.guesses)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: CupertinoButton(
                    key: ValueKey('dateGuess:${g.label}'),
                    color: const Color(0xFF2C2C2E),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    onPressed: () => _use(g.date),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            g.label,
                            style: const TextStyle(
                              fontSize: 15,
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                        ),
                        Text(
                          format.format(g.date),
                          style: const TextStyle(
                            fontSize: 15,
                            color: CupertinoColors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _setFields(AppLocalizations l10n) => [
    Row(
      children: [
        _box(l10n.dateEditYear, _year, 4, flex: 2, key: 'year'),
        _box(l10n.dateEditMonth, _month, 2, key: 'month'),
        _box(l10n.dateEditDay, _day, 2, key: 'day'),
      ],
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        _box(l10n.dateEditHour, _hour, 2, key: 'hour'),
        _box(l10n.dateEditMinute, _minute, 2, key: 'minute'),
        const Spacer(),
      ],
    ),
  ];

  List<Widget> _shiftFields(AppLocalizations l10n) => [
    CupertinoSlidingSegmentedControl<bool>(
      groupValue: _later,
      onValueChanged: (v) => setState(() => _later = v ?? _later),
      children: {
        false: Text(l10n.dateEditEarlier),
        true: Text(l10n.dateEditLater),
      },
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        _box(l10n.dateEditYears, _years, 3, key: 'years'),
        _box(l10n.dateEditMonths, _months, 3, key: 'months'),
        _box(l10n.dateEditDays, _days, 4, key: 'days'),
        _box(l10n.dateEditHours, _hours, 4, key: 'hours'),
      ],
    ),
  ];

  Widget _box(
    String label,
    TextEditingController controller,
    int digits, {
    required String key,
    int flex = 1,
  }) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: CupertinoColors.systemGrey,
            ),
          ),
          const SizedBox(height: 4),
          CupertinoTextField(
            key: ValueKey('dateEdit:$key'),
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(digits),
            ],
            textAlign: TextAlign.center,
            placeholder: '0',
            style: const TextStyle(
              fontSize: 20,
              color: CupertinoColors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E),
              borderRadius: BorderRadius.circular(8),
            ),
            onTap: () => controller.selection = TextSelection(
              baseOffset: 0,
              extentOffset: controller.text.length,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    ),
  );
}
