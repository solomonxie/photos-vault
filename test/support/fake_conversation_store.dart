import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/photos/conversation_store.dart';

/// In-memory [ConversationStore] for widget tests.
class FakeConversationStore implements ConversationStore {
  final rows = <String, (String, ConversationMessage)>{};
  final pending = <String>{};

  @override
  Future<bool> copyTo(String dest) async => false;

  @override
  Future<int> mergeFrom(String path) async => 0;

  @override
  Future<int> dataMark() async => rows.length;

  List<ConversationMessage> _of(String personId) =>
      [
        for (final (id, m) in rows.values)
          if (id == personId) m,
      ]..sort((a, b) {
        final byAt = b.at.compareTo(a.at);
        return byAt != 0 ? byAt : b.hash.compareTo(a.hash);
      });

  @override
  Future<void> close() async {}

  @override
  Future<bool> hasMessageAt(String personId, DateTime at) async =>
      _of(personId).any((m) => m.at == at);

  @override
  Future<DateTime?> latestFor(String personId) async =>
      _of(personId).firstOrNull?.at;

  @override
  Future<Map<String, DateTime>> latestByPerson() async => {
    for (final id in {for (final (id, _) in rows.values) id})
      id: _of(id).first.at,
  };

  @override
  Future<int> insert(
    String personId,
    List<ConversationMessage> messages, {
    void Function(int done)? onProgress,
  }) async {
    var added = 0;
    for (final m in messages) {
      if (rows.containsKey(m.hash)) continue;
      rows[m.hash] = (personId, m);
      added++;
    }
    if (added > 0) pending.add(personId);
    onProgress?.call(messages.length);
    return added;
  }

  @override
  Future<Map<String, Map<String, int>>> countsBySource() async {
    final out = <String, Map<String, int>>{};
    for (final (id, m) in rows.values) {
      final of = out[id] ??= {};
      of[m.source] = (of[m.source] ?? 0) + 1;
    }
    return out;
  }

  @override
  Future<Map<String, int>> countsByPerson() async {
    final out = <String, int>{};
    for (final (id, _) in rows.values) {
      out[id] = (out[id] ?? 0) + 1;
    }
    return out;
  }

  @override
  Future<int> countFor(String personId) async => _of(personId).length;

  @override
  Future<Map<(int, int), int>> monthsOf(String personId) async {
    final out = <(int, int), int>{};
    for (final m in _of(personId)) {
      final k = (m.at.year, m.at.month);
      out[k] = (out[k] ?? 0) + 1;
    }
    return out;
  }

  @override
  Future<List<ConversationChat>> chatsOf(String personId) async {
    final counts = <(String, String), int>{};
    for (final m in _of(personId)) {
      counts[(m.chat, m.source)] = (counts[(m.chat, m.source)] ?? 0) + 1;
    }
    return [
      for (final MapEntry(:key, :value) in counts.entries)
        ConversationChat(key.$1, key.$2, value),
    ];
  }

  @override
  Future<List<ConversationMessage>> page(
    String personId, {
    ConversationMessage? before,
    int limit = 200,
  }) async {
    final all = _of(personId);
    final start = before == null
        ? 0
        : all.indexWhere((m) => m.hash == before.hash) + 1;
    return all.skip(start).take(limit).toList();
  }

  @override
  Future<List<ConversationMessage>> search(
    String personId,
    String query, {
    int limit = 200,
  }) async => [
    for (final m in _of(personId))
      if (query.trim().isNotEmpty && m.text.contains(query.trim())) m,
  ].take(limit).toList();

  @override
  Future<void> movePerson(String from, String to) async {
    var moved = 0;
    for (final MapEntry(:key, value: (id, m)) in rows.entries.toList()) {
      if (id != from) continue;
      rows[key] = (to, m);
      moved++;
    }
    pending.remove(from);
    if (moved > 0) pending.add(to);
  }

  @override
  Future<Map<String, (DateTime, DateTime)>> pendingSpans() async => {
    for (final id in pending)
      if (_of(id) case [final newest, ..., final oldest])
        id: (oldest.at, newest.at)
      else if (_of(id) case [final only])
        id: (only.at, only.at),
  };

  @override
  Future<void> clearPending(Iterable<String> personIds) async =>
      pending.removeAll(personIds);

  @override
  Future<void> forgetPerson(String personId) async {
    rows.removeWhere((_, v) => v.$1 == personId);
    pending.remove(personId);
  }
}
