import 'dart:async';

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

enum _Open { date, time }

/// The date and the time as two parts, either of which can be left alone
/// (each photo then keeps its own). Reports what to do to a photo's date,
/// or null when both parts are off.
class SetDateParts extends StatefulWidget {
  const SetDateParts({
    super.key,
    required this.initial,
    required this.guesses,
    required this.onChanged,
  });

  final DateTime initial;
  final List<DateGuess> guesses;
  final void Function(DateTime Function(DateTime)? change) onChanged;

  @override
  State<SetDateParts> createState() => _SetDatePartsState();
}

class _SetDatePartsState extends State<SetDateParts> {
  late var _at = widget.initial;
  _Open? _open;
  var _dateOn = true;
  var _timeOn = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  void _report() {
    if (!mounted) return;
    if (!_dateOn && !_timeOn) return widget.onChanged(null);
    final picked = _at;
    final date = _dateOn, time = _timeOn;
    widget.onChanged((from) {
      final f = from.toLocal();
      return DateTime(
        date ? picked.year : f.year,
        date ? picked.month : f.month,
        date ? picked.day : f.day,
        time ? picked.hour : f.hour,
        time ? picked.minute : f.minute,
        f.second,
      );
    });
  }

  void _change(VoidCallback fn) {
    setState(fn);
    _report();
  }

  void _use(DateTime d) => _change(() {
    _at = d;
    _open = null;
    _dateOn = _timeOn = true;
  });

  void _toggle(_Open which) =>
      setState(() => _open = _open == which ? null : which);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final format = DateFormat.yMMMMEEEEd().add_jm();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.guesses.isNotEmpty) ...[
          Text(
            l10n.dateEditSuggested.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              color: CupertinoColors.systemGrey,
            ),
          ),
          const SizedBox(height: 6),
          for (final g in widget.guesses) _guess(g, format),
          const SizedBox(height: 12),
        ],
        _row(
          key: 'dateRow',
          part: l10n.dateEditDatePart,
          on: _dateOn,
          onToggle: (v) => _change(() {
            _dateOn = v;
            if (!v && _open == _Open.date) _open = null;
          }),
          open: _Open.date,
          text: DateFormat.yMMMMEEEEd().format(_at),
          picker: CupertinoDatePicker(
            key: const ValueKey('datePicker'),
            mode: CupertinoDatePickerMode.date,
            initialDateTime: _at,
            minimumYear: 1900,
            maximumDate: DateTime.now(),
            onDateTimeChanged: (d) => _change(
              () => _at = DateTime(
                d.year,
                d.month,
                d.day,
                _at.hour,
                _at.minute,
                _at.second,
              ),
            ),
          ),
        ),
        _row(
          key: 'timeRow',
          part: l10n.dateEditTimePart,
          on: _timeOn,
          onToggle: (v) => _change(() {
            _timeOn = v;
            if (!v && _open == _Open.time) _open = null;
          }),
          open: _Open.time,
          text: DateFormat.jm().format(_at),
          picker: CupertinoDatePicker(
            key: const ValueKey('timePicker'),
            mode: CupertinoDatePickerMode.time,
            initialDateTime: _at,
            onDateTimeChanged: (d) => _change(
              () => _at = DateTime(
                _at.year,
                _at.month,
                _at.day,
                d.hour,
                d.minute,
                _at.second,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _guess(DateGuess g, DateFormat format) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: CupertinoButton(
      key: ValueKey('dateGuess:${g.label}'),
      color: const Color(0xFF2C2C2E),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
            style: const TextStyle(fontSize: 15, color: CupertinoColors.white),
          ),
        ],
      ),
    ),
  );

  Widget _row({
    required String key,
    required String part,
    required bool on,
    required ValueChanged<bool> onToggle,
    required _Open open,
    required String text,
    required Widget picker,
  }) {
    final shown = on && _open == open;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  part.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 12,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
              ),
              CupertinoSwitch(
                key: ValueKey('${key}Switch'),
                value: on,
                onChanged: onToggle,
              ),
            ],
          ),
        ),
        Opacity(
          opacity: on ? 1 : 0.4,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                CupertinoButton(
                  key: ValueKey(key),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  onPressed: () {
                    if (!on) onToggle(true);
                    _toggle(open);
                  },
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          text,
                          style: TextStyle(
                            fontSize: 17,
                            color: shown
                                ? CupertinoColors.activeBlue
                                : CupertinoColors.white,
                          ),
                        ),
                      ),
                      Icon(
                        shown
                            ? CupertinoIcons.chevron_up
                            : CupertinoIcons.chevron_down,
                        size: 16,
                        color: CupertinoColors.systemGrey,
                      ),
                    ],
                  ),
                ),
                if (shown) SizedBox(height: 200, child: picker),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The photo's date and time on one line, in place: a tap on the date opens
/// its wheels under the line, a tap on the time opens the time wheels.
/// Every change is saved after a short rest of the wheel, and on closing —
/// there is no Save button to forget.
class InlineDateRow extends StatefulWidget {
  const InlineDateRow({
    super.key,
    required this.at,
    required this.onChanged,
    this.loadGuesses,
  });

  final DateTime at;
  final void Function(DateTime at) onChanged;

  /// Likely dates, read the first time the wheels open.
  final Future<List<DateGuess>> Function()? loadGuesses;

  @override
  State<InlineDateRow> createState() => _InlineDateRowState();
}

class _InlineDateRowState extends State<InlineDateRow> {
  late var _at = widget.at.toLocal();
  _Open? _open;
  List<DateGuess>? _guesses;
  Timer? _rest;
  bool _dirty = false;

  @override
  void didUpdateWidget(InlineDateRow old) {
    super.didUpdateWidget(old);
    if (!_dirty && old.at != widget.at) _at = widget.at.toLocal();
  }

  @override
  void dispose() {
    _rest?.cancel();
    if (_dirty) {
      // After this frame: the page above is being torn down too.
      final save = widget.onChanged, at = _at;
      Future.microtask(() => save(at));
    }
    super.dispose();
  }

  void _flush() {
    _rest?.cancel();
    if (!_dirty) return;
    _dirty = false;
    widget.onChanged(_at);
  }

  void _set(DateTime at) {
    setState(() => _at = at);
    _dirty = true;
    _rest?.cancel();
    _rest = Timer(const Duration(milliseconds: 700), _flush);
  }

  Future<void> _toggle(_Open which) async {
    final closing = _open == which;
    if (closing) _flush();
    setState(() => _open = closing ? null : which);
    if (!closing && _guesses == null && widget.loadGuesses != null) {
      final found = await widget.loadGuesses!();
      if (mounted) setState(() => _guesses = found);
    }
  }

  @override
  Widget build(BuildContext context) {
    final guesses = [
      for (final g in _guesses ?? const <DateGuess>[])
        if (g.date != _at) g,
    ];
    Widget part(String key, String text, _Open which) => CupertinoButton(
      key: ValueKey(key),
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: () => _toggle(which),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: _open == which
              ? CupertinoColors.activeBlue
              : CupertinoColors.white,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            part('dateRow', DateFormat.yMMMd().format(_at), _Open.date),
            const SizedBox(width: 14),
            part('timeRow', DateFormat.jm().format(_at), _Open.time),
          ],
        ),
        if (_open != null) ...[
          for (final g in guesses)
            CupertinoButton(
              key: ValueKey('dateGuess:${g.label}'),
              padding: const EdgeInsets.only(top: 8),
              minimumSize: Size.zero,
              onPressed: () => _set(g.date),
              child: Text(
                '${g.label}  ·  ${DateFormat.yMMMd().add_jm().format(g.date)}',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          SizedBox(
            height: 200,
            child: _open == _Open.date
                ? CupertinoDatePicker(
                    key: const ValueKey('datePicker'),
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: _at,
                    minimumYear: 1900,
                    maximumDate: DateTime.now(),
                    onDateTimeChanged: (d) => _set(
                      DateTime(
                        d.year,
                        d.month,
                        d.day,
                        _at.hour,
                        _at.minute,
                        _at.second,
                      ),
                    ),
                  )
                : CupertinoDatePicker(
                    key: const ValueKey('timePicker'),
                    mode: CupertinoDatePickerMode.time,
                    initialDateTime: _at,
                    onDateTimeChanged: (d) => _set(
                      DateTime(
                        _at.year,
                        _at.month,
                        _at.day,
                        d.hour,
                        d.minute,
                        _at.second,
                      ),
                    ),
                  ),
          ),
        ],
      ],
    );
  }
}

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
  DateTime Function(DateTime)? _setChange;

  final _years = TextEditingController();
  final _months = TextEditingController();
  final _days = TextEditingController();
  final _hours = TextEditingController();

  @override
  void dispose() {
    for (final c in [_years, _months, _days, _hours]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _int(TextEditingController c) => int.tryParse(c.text.trim());

  DateTime Function(DateTime)? get _result {
    if (_mode == _Mode.set) return _setChange;
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final result = _result;
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
            if (widget.count > 1) ...[
              CupertinoSlidingSegmentedControl<_Mode>(
                groupValue: _mode,
                onValueChanged: (m) => setState(() => _mode = m ?? _mode),
                children: {
                  _Mode.set: Text(l10n.dateEditSetAll),
                  _Mode.shift: Text(l10n.dateEditShiftAll),
                },
              ),
              const SizedBox(height: 20),
            ],
            if (_mode == _Mode.set)
              SetDateParts(
                initial: widget.initial,
                guesses: widget.guesses,
                onChanged: (c) => setState(() => _setChange = c),
              )
            else ...[
              Text(
                result == null
                    ? format.format(widget.initial)
                    : format.format(result(widget.initial)),
                key: const ValueKey('dateEditPreview'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.white,
                ),
              ),
              const SizedBox(height: 16),
              ..._shiftFields(l10n),
            ],
          ],
        ),
      ),
    );
  }

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
