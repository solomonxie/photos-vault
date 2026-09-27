import 'app_snapshot.dart';

/// The library as one CSV a person can read.
///
/// Everything else in this folder is written for the app to read back.
/// This is written for the case where there is no app: the phone is gone,
/// the account is gone, and what's left is a bucket holding tens of
/// thousands of objects named after iOS asset identifiers —
/// `originals/B84E8479-…_L0_001.HEIC` — which say nothing about when the
/// photo was taken, who is in it, or which album it belonged to.
///
/// One row per photo, `taken_at` first so a sort by column one is the
/// library in order. Opens in Numbers, Excel, `sort`, `grep` or a text
/// editor, needs nothing installed, and will still open in twenty years.
/// A few hundred kilobytes next to gigabytes of photos.
///
/// **Not everything is in it.** Hidden photos are left out on purpose: a
/// private album's objects are encrypted carriers that look like ordinary
/// pictures, and a plaintext index sitting beside them naming what they
/// really are would undo the whole point (see `../vault/`). Binned photos
/// are out because they are not in the library.
const indexEntryName = 'index.csv';

const _columns = [
  'taken_at',
  'type',
  'file',
  'albums',
  'people',
  'caption',
  'tags',
  'place',
  'original_key',
  'thumbnail_key',
];

/// Renders [snapshot] as CSV — RFC 4180 quoting, `\r\n` line endings, which
/// is what spreadsheet apps expect from a `.csv` they didn't write.
String indexCsv(AppSnapshot snapshot) {
  final albumsBy = _membership(snapshot.albums);
  final peopleBy = _membership(snapshot.people);

  final rows = <List<String>>[];
  for (final asset in snapshot.assets) {
    if (asset['deletedAt'] != null) continue;
    if (asset['isHidden'] as bool? ?? false) continue;
    if (asset['passcodeHash'] != null) continue;

    final localId = asset['localId'] as String? ?? '';
    final derivatives = asset['derivatives'] as Map<String, Object?>? ?? {};
    final originalKey = _keyOf(derivatives, 'original');
    rows.add([
      asset['createdAt'] as String? ?? '',
      _typeOf(asset),
      originalKey.isEmpty ? '' : originalKey.split('/').last,
      (albumsBy[localId] ?? const []).join('; '),
      (peopleBy[localId] ?? const []).join('; '),
      asset['description'] as String? ?? '',
      _tagsOf(asset['tags']),
      asset['location'] as String? ?? '',
      originalKey,
      _keyOf(derivatives, 'thumbnail'),
    ]);
  }
  // By the date in column one, so the file itself is chronological and
  // nobody has to sort it to use it.
  rows.sort((a, b) => a.first.compareTo(b.first));

  return [_line(_columns), for (final row in rows) _line(row)].join();
}

/// `localId -> names`, from the `localIds` list each album and person row
/// carries. Inverted once rather than searched per photo: a library of
/// thirty thousand against a few hundred albums is otherwise a few million
/// list scans.
Map<String, List<String>> _membership(List<Map<String, Object?>> groups) {
  final byLocalId = <String, List<String>>{};
  for (final group in groups) {
    final name = group['name'] as String?;
    if (name == null || name.isEmpty) continue;
    for (final id in (group['localIds'] as List<dynamic>? ?? const [])) {
      if (id is String) (byLocalId[id] ??= []).add(name);
    }
  }
  return byLocalId;
}

String _typeOf(Map<String, Object?> asset) {
  if (asset['isVideo'] as bool? ?? false) return 'video';
  if (asset['isLivePhoto'] as bool? ?? false) return 'live photo';
  if (asset['isGif'] as bool? ?? false) return 'gif';
  return 'photo';
}

String _keyOf(Map<String, Object?> derivatives, String kind) {
  final state = derivatives[kind] as Map<String, Object?>?;
  return state?['destinationKey'] as String? ?? '';
}

String _tagsOf(Object? tags) => switch (tags) {
  List<dynamic> list => list.whereType<String>().join('; '),
  String single => single,
  _ => '',
};

String _line(List<String> cells) => '${cells.map(_cell).join(',')}\r\n';

/// Quoted when it has to be, which for a caption typed by a person is
/// often: a comma, a quote, or a newline in a field is what turns a CSV
/// into a file that opens misaligned and gets blamed on the app.
String _cell(String value) {
  if (!value.contains(RegExp('[",\r\n]'))) return value;
  return '"${value.replaceAll('"', '""')}"';
}
