/// First, middle and last guessed from a display name: words for a spaced
/// name ("Mia Jane Wu"), surname first for a Chinese one ("王小明" → 王,
/// 小明). Empty parts where there's nothing to go on.
({String first, String middle, String last}) suggestNameParts(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return (first: '', middle: '', last: '');
  if (_cjk.hasMatch(trimmed) && !trimmed.contains(' ')) {
    if (trimmed.length < 2) return (first: trimmed, middle: '', last: '');
    final surname =
        _compoundSurnames.any(trimmed.startsWith) && trimmed.length > 2
        ? trimmed.substring(0, 2)
        : trimmed.substring(0, 1);
    return (
      first: trimmed.substring(surname.length),
      middle: '',
      last: surname,
    );
  }
  final words = trimmed.split(RegExp(r'\s+'));
  if (words.length == 1) return (first: words.single, middle: '', last: '');
  return (
    first: words.first,
    middle: words.sublist(1, words.length - 1).join(' '),
    last: words.last,
  );
}

final _cjk = RegExp(r'[㐀-鿿]');

const _compoundSurnames = [
  '欧阳',
  '司马',
  '诸葛',
  '上官',
  '东方',
  '皇甫',
  '尉迟',
  '公孙',
  '慕容',
  '夏侯',
  '令狐',
  '长孙',
  '宇文',
  '司徒',
  '端木',
  '歐陽',
  '司馬',
  '諸葛',
  '東方',
];
