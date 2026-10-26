import 'person.dart';

/// A name or handle an import once put on someone: what it called them,
/// so the next import of the same file knows them without asking.
class KnownAs {
  const KnownAs({
    required this.personId,
    required this.kind,
    required this.value,
  });

  /// A name as an import spelt it ("Mia C."), or where it came from — a
  /// chat ("wechat:wxid_…", "sms:+1555…").
  static const name = 'name';
  static const handle = 'handle';

  final String personId;
  final String kind;
  final String value;

  String get key => keyOf(kind, value);

  static String keyOf(String kind, String value) =>
      kind == handle ? value.trim().toLowerCase() : nameKey(value);
}

/// Case and spacing folded: "  mia   CHEN" is "mia chen".
String nameKey(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Who an import's name or handles were last time: remembered names and
/// handles, and names people had before a rename or merge. One read of
/// each, then lookups in memory.
class KnownNames {
  KnownNames(
    Iterable<Person> people, {
    Iterable<KnownAs> known = const [],
    Map<String, List<String>> former = const {},
    Map<String, Set<String>> handles = const {},
  }) {
    final byId = {for (final p in people) p.id: p};
    void add(Map<String, List<Person>> into, String key, String id) {
      final person = byId[id];
      if (person == null || key.isEmpty) return;
      final list = into.putIfAbsent(key, () => []);
      if (!list.any((p) => p.id == id)) list.add(person);
    }

    for (final k in known) {
      add(k.kind == KnownAs.handle ? _byHandle : _byName, k.key, k.personId);
    }
    for (final MapEntry(key: id, value: names) in former.entries) {
      for (final n in names) {
        add(_byName, nameKey(n), id);
      }
    }
    for (final MapEntry(key: id, value: chats) in handles.entries) {
      for (final h in chats) {
        add(_byHandle, KnownAs.keyOf(KnownAs.handle, h), id);
      }
    }
  }

  static final none = KnownNames(const []);

  final _byName = <String, List<Person>>{};
  final _byHandle = <String, List<Person>>{};

  /// Everyone [name] or any of [handles] was before, handles first.
  List<Person> of(String name, [Iterable<String> handles = const []]) {
    final out = <Person>[];
    void addAll(List<Person>? people) {
      for (final p in people ?? const <Person>[]) {
        if (!out.any((o) => o.id == p.id)) out.add(p);
      }
    }

    for (final h in handles) {
      addAll(_byHandle[KnownAs.keyOf(KnownAs.handle, h)]);
    }
    addAll(_byName[nameKey(name)]);
    return out;
  }

  /// Who this is, remembered: the one person their handles were, or with
  /// no handle known, the one their name was. Null when nobody, or several.
  Person? remembered(String name, [Iterable<String> handles = const []]) {
    final byHandle = <Person>[];
    for (final h in handles) {
      for (final p in _byHandle[KnownAs.keyOf(KnownAs.handle, h)] ?? const []) {
        if (!byHandle.any((o) => o.id == p.id)) byHandle.add(p);
      }
    }
    if (byHandle.isNotEmpty) {
      return byHandle.length == 1 ? byHandle.single : null;
    }
    final byName = _byName[nameKey(name)] ?? const [];
    return byName.length == 1 ? byName.single : null;
  }
}
