/// Profiles as a spreadsheet: one row per person, one column per named
/// field, and anything repeating packed into a single cell.
///
/// A spreadsheet is the one format everybody already has an editor for, and
/// a profile is mostly a form — so the columns are the form's rows, in the
/// order the profile shows them. Repeating parts (jobs, groups, places) are
/// `;`-separated items whose own parts are split by `|`, which keeps one
/// person on one line: a file where somebody spans four rows is a file that
/// cannot be sorted, filtered, or read in the app that opens it.
///
/// Read tolerantly, written strictly. Unknown columns are ignored and every
/// column but `name` is optional, because a file that came back from a
/// spreadsheet has been through hands this app does not control.
library;

import 'person.dart';
import 'person_detail.dart';

/// The columns, in order. The header names them, and the reader goes by the
/// header rather than by position.
final profileCsvColumns = [
  'name',
  'birthdate',
  'gender',
  'bio',
  ...profileCsvTraitColumns,
  'fields',
  'groups',
  'education',
  'jobs',
  'places',
  'tags',
];

/// One column per named trait — `hair`, `eyes`, and the rest. Taken from
/// [personTraits] rather than listed again, so a trait added to the profile
/// is a column in the file without anybody remembering to add it here.
final profileCsvTraitColumns = [for (final trait in personTraits) trait.key];

const _itemSeparator = ';';
const _partSeparator = '|';

/// What went wrong on one line, in terms the screen can put in the reader's
/// language. The line survives so the answer can be "fix line 14", which is
/// the only answer that helps with a 300-row file.
enum ProfileCsvProblem { noHeader, noNameColumn, missingName }

class ProfileCsvNote {
  const ProfileCsvNote(this.line, this.problem);

  final int line;
  final ProfileCsvProblem problem;
}

/// One person as the file describes them — no ids, no store, nothing written.
/// The screen shows these, and only what is accepted becomes rows.
class ProfileCsvRow {
  const ProfileCsvRow({
    required this.name,
    this.birthDate,
    this.gender,
    this.bio = '',
    this.traits = const {},
    this.fields = const [],
    this.groups = const [],
    this.education = const [],
    this.jobs = const [],
    this.places = const [],
    this.tags = const [],
  });

  final String name;
  final DateTime? birthDate;
  final Gender? gender;
  final String bio;
  final Map<String, String> traits;
  final List<PersonCustomField> fields;
  final List<ProfileCsvGroup> groups;
  final List<ProfileCsvHistory> education;
  final List<ProfileCsvHistory> jobs;
  final List<String> places;
  final List<String> tags;

  /// How much this row would add beyond the name — what the review list
  /// shows, so a row that is only a name is visibly only a name.
  int get itemCount =>
      (bio.isEmpty ? 0 : 1) +
      (birthDate == null ? 0 : 1) +
      (gender == null ? 0 : 1) +
      traits.values.where((v) => v.isNotEmpty).length +
      fields.length +
      groups.length +
      education.length +
      jobs.length +
      places.length +
      tags.length;
}

class ProfileCsvGroup {
  const ProfileCsvGroup(this.name, this.kind);

  final String name;
  final GroupKind kind;
}

/// A school or a job, as one `Title|Detail|Start|End` item. `Detail` is the
/// degree or the role, and lands in the entry's notes.
class ProfileCsvHistory {
  const ProfileCsvHistory({
    required this.title,
    this.detail = '',
    this.start,
    this.end,
  });

  final String title;
  final String detail;
  final DateTime? start;
  final DateTime? end;
}

/// What a file turned out to hold.
class ProfileCsvFile {
  const ProfileCsvFile({this.rows = const [], this.notes = const []});

  final List<ProfileCsvRow> rows;
  final List<ProfileCsvNote> notes;
}

// -------------------------------------------------------------- reading

/// Reads the file. Never throws: a file this cannot make sense of produces a
/// note, and a note is something the screen can show.
ProfileCsvFile readProfileCsv(String text) {
  // A spreadsheet that saved this file may have led with a byte-order mark,
  // which would otherwise make the first column something other than `name`.
  final grid = decodeDelimited(text.replaceFirst('\uFEFF', ''));
  if (grid.isEmpty) {
    return const ProfileCsvFile(
      notes: [ProfileCsvNote(1, ProfileCsvProblem.noHeader)],
    );
  }
  final header = [for (final cell in grid.first) _key(cell)];
  final nameAt = header.indexOf('name');
  if (nameAt < 0) {
    return const ProfileCsvFile(
      notes: [ProfileCsvNote(1, ProfileCsvProblem.noNameColumn)],
    );
  }
  final rows = <ProfileCsvRow>[];
  final notes = <ProfileCsvNote>[];
  for (var i = 1; i < grid.length; i++) {
    final cells = grid[i];
    if (cells.every((c) => c.trim().isEmpty)) continue;
    String at(String column) {
      final index = header.indexOf(column);
      if (index < 0 || index >= cells.length) return '';
      return cells[index].trim();
    }

    final name = at('name');
    if (name.isEmpty) {
      notes.add(ProfileCsvNote(i + 1, ProfileCsvProblem.missingName));
      continue;
    }
    rows.add(
      ProfileCsvRow(
        name: name,
        birthDate: parseProfileCsvDate(at('birthdate')),
        gender: Gender.values
            .where((g) => g.name == at('gender').toLowerCase())
            .firstOrNull,
        bio: at('bio'),
        traits: {
          for (final trait in profileCsvTraitColumns)
            if (at(trait).isNotEmpty) trait: at(trait),
        },
        fields: [
          for (final item in _items(at('fields')))
            if (_parts(item) case [final label, ...final rest])
              PersonCustomField(label: label, value: rest.join(_partSeparator)),
        ],
        groups: [
          for (final item in _items(at('groups')))
            if (_parts(item) case [final groupName, ...final rest])
              ProfileCsvGroup(groupName, _groupKind(rest.firstOrNull)),
        ],
        education: [for (final item in _items(at('education'))) _history(item)],
        jobs: [for (final item in _items(at('jobs'))) _history(item)],
        places: _items(at('places')),
        tags: [for (final tag in _items(at('tags'))) tag.toLowerCase()],
      ),
    );
  }
  return ProfileCsvFile(rows: rows, notes: notes);
}

/// `Title|Detail|Start|End`, all but the title optional.
ProfileCsvHistory _history(String item) {
  final parts = _parts(item);
  return ProfileCsvHistory(
    title: parts.first,
    detail: parts.length > 1 ? parts[1] : '',
    start: parts.length > 2 ? parseProfileCsvDate(parts[2]) : null,
    end: parts.length > 3 ? parseProfileCsvDate(parts[3]) : null,
  );
}

GroupKind _groupKind(String? value) =>
    GroupKind.values
        .where((k) => k.name == value?.trim().toLowerCase())
        .firstOrNull ??
    GroupKind.circle;

List<String> _items(String cell) => [
  for (final part in cell.split(_itemSeparator))
    if (part.trim().isNotEmpty) part.trim(),
];

List<String> _parts(String item) => [
  for (final part in item.split(_partSeparator)) part.trim(),
];

/// Header names are matched loosely — `Birth Date`, `birth_date` and
/// `birthdate` are the same column, because the file has been through a
/// spreadsheet and somebody has retyped the header.
String _key(String cell) =>
    cell.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');

/// `2019`, `2019-06` and `2019-06-14` all read, since a job somebody
/// remembers the year of should not need a day invented for it. Out-of-range
/// parts give up rather than rolling over into the next month.
DateTime? parseProfileCsvDate(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final parts = trimmed.split(RegExp(r'[-/.]'));
  final numbers = [for (final part in parts) int.tryParse(part.trim())];
  if (numbers.isEmpty || numbers.first == null) return null;
  if (numbers.any((n) => n == null)) return null;
  final year = numbers[0]!;
  final month = numbers.length > 1 ? numbers[1]! : 1;
  final day = numbers.length > 2 ? numbers[2]! : 1;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime(year, month, day);
  if (date.month != month || date.day != day) return null;
  return date;
}

String formatProfileCsvDate(DateTime? date) {
  if (date == null) return '';
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year.toString().padLeft(4, '0')}-$month-$day';
}

// -------------------------------------------------------------- writing

String writeProfileCsv(Iterable<ProfileCsvRow> rows) => encodeDelimited([
  profileCsvColumns,
  for (final row in rows)
    [
      row.name,
      formatProfileCsvDate(row.birthDate),
      row.gender?.name ?? '',
      row.bio,
      for (final trait in profileCsvTraitColumns) row.traits[trait] ?? '',
      _join([
        for (final field in row.fields) _joinParts([field.label, field.value]),
      ]),
      _join([
        for (final group in row.groups)
          _joinParts([group.name, group.kind.name]),
      ]),
      _join([for (final entry in row.education) _historyCell(entry)]),
      _join([for (final entry in row.jobs) _historyCell(entry)]),
      _join(row.places),
      _join(row.tags),
    ],
]);

String _historyCell(ProfileCsvHistory entry) => _joinParts([
  entry.title,
  entry.detail,
  formatProfileCsvDate(entry.start),
  formatProfileCsvDate(entry.end),
]);

String _join(Iterable<String> items) => items
    .map((i) => i.replaceAll(_itemSeparator, ' '))
    .where((i) => i.trim().isNotEmpty)
    .join('$_itemSeparator ');

/// Trailing empties dropped, so a job with no dates is `Acme|Engineer`
/// rather than `Acme|Engineer||`.
String _joinParts(List<String> parts) {
  final cleaned = [for (final p in parts) p.replaceAll(_partSeparator, ' ')];
  while (cleaned.isNotEmpty && cleaned.last.trim().isEmpty) {
    cleaned.removeLast();
  }
  return cleaned.join(_partSeparator);
}

// ------------------------------------------------------- the format itself

/// Splits comma-separated text into rows of cells, honouring quotes: a bio
/// with a comma in it, or a newline, is one cell — which is the whole reason
/// this is not `split(',')`.
List<List<String>> decodeDelimited(String text) {
  final rows = <List<String>>[];
  var cells = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  var index = 0;
  var sawCell = false;

  void endCell() {
    cells.add(cell.toString());
    cell.clear();
    sawCell = false;
  }

  void endRow() {
    endCell();
    rows.add(cells);
    cells = <String>[];
  }

  while (index < text.length) {
    final char = text[index];
    if (quoted) {
      if (char == '"') {
        // A doubled quote is a literal one; a single quote closes the cell.
        if (index + 1 < text.length && text[index + 1] == '"') {
          cell.write('"');
          index += 2;
          continue;
        }
        quoted = false;
        index++;
        continue;
      }
      cell.write(char);
      index++;
      continue;
    }
    if (char == '"' && !sawCell) {
      quoted = true;
      sawCell = true;
      index++;
      continue;
    }
    if (char == ',') {
      endCell();
      index++;
      continue;
    }
    if (char == '\n' || char == '\r') {
      endRow();
      // \r\n is one break, not two.
      index +=
          (char == '\r' && index + 1 < text.length && text[index + 1] == '\n')
          ? 2
          : 1;
      continue;
    }
    cell.write(char);
    sawCell = true;
    index++;
  }
  if (cell.isNotEmpty || cells.isNotEmpty) endRow();
  return rows;
}

String encodeDelimited(List<List<String>> rows) =>
    rows.map((row) => row.map(_quote).join(',')).join('\n');

String _quote(String cell) => cell.contains(RegExp('[",\n\r]'))
    ? '"${cell.replaceAll('"', '""')}"'
    : cell;
