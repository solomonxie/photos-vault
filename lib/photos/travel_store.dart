import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show
        ConflictAlgorithm,
        Database,
        DatabaseExecutor,
        DatabaseFactory,
        OpenDatabaseOptions;
import 'package:uuid/uuid.dart';

import '../backup/database_copy.dart';
import 'travel.dart';

/// `travel.db`: places, diary entries and impressions, routes with their
/// stops and legs, and the photos and people linked to them. See
/// `docs/design/travel-diary.md`.
///
/// Backed up as a blob by `DataFiles` like `words.db`: [copyTo],
/// [mergeFrom], and [dataMark], which moves on every write (a `rev`
/// counter bumped in the same transaction), edits included.
///
/// Reads are one query each; links for many owners come back from one
/// query and are grouped here ([linksFor]).
class TravelStore {
  TravelStore({DatabaseFactory? databaseFactory, String? path, Uuid? uuid})
    : this._(databaseFactory, path, uuid ?? const Uuid());

  TravelStore._(this._databaseFactory, this._path, this._uuid);

  final DatabaseFactory? _databaseFactory;
  DatabaseFactory get _factory => _databaseFactory ?? sqflite.databaseFactory;
  final String? _path;
  final Uuid _uuid;

  static const fileName = 'travel.db';
  static const _tables = ['place', 'entry', 'route', 'stop', 'leg', 'link'];

  /// SQLite's bound-variable limit is 999 on older builds.
  static const _chunk = 500;

  Database? _db;
  Future<Database>? _opening;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final opening = _opening ??= _openOnce();
    try {
      return await opening;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _openOnce() async {
    final path = _path ?? p.join(await _factory.getDatabasesPath(), fileName);
    return _db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, onCreate: _create),
    );
  }

  static Future<void> _create(Database db, int version) async {
    final batch = db.batch()
      ..execute('''
        CREATE TABLE place (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          kind TEXT NOT NULL,
          lat REAL NOT NULL,
          lng REAL NOT NULL,
          parent_id TEXT,
          country TEXT NOT NULL DEFAULT '',
          created_at INTEGER NOT NULL
        )
      ''')
      ..execute('CREATE INDEX place_parent ON place (parent_id)')
      ..execute('''
        CREATE TABLE entry (
          id TEXT PRIMARY KEY,
          place_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          at INTEGER,
          title TEXT NOT NULL DEFAULT '',
          text TEXT NOT NULL DEFAULT '',
          rating INTEGER,
          tags TEXT NOT NULL DEFAULT '[]',
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''')
      ..execute('CREATE INDEX entry_place_at ON entry (place_id, at)')
      ..execute('''
        CREATE TABLE route (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          note TEXT NOT NULL DEFAULT '',
          starts INTEGER,
          ends INTEGER,
          created_at INTEGER NOT NULL
        )
      ''')
      ..execute('''
        CREATE TABLE stop (
          route_id TEXT NOT NULL,
          position INTEGER NOT NULL,
          place_id TEXT NOT NULL,
          arrived INTEGER,
          note TEXT NOT NULL DEFAULT '',
          PRIMARY KEY (route_id, position)
        )
      ''')
      ..execute('CREATE INDEX stop_place ON stop (place_id)')
      ..execute('''
        CREATE TABLE leg (
          route_id TEXT NOT NULL,
          position INTEGER NOT NULL,
          mode TEXT NOT NULL,
          note TEXT NOT NULL DEFAULT '',
          from_place TEXT NOT NULL DEFAULT '',
          to_place TEXT NOT NULL DEFAULT '',
          needs_review INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (route_id, position)
        )
      ''')
      ..execute('''
        CREATE TABLE link (
          owner_kind TEXT NOT NULL,
          owner_id TEXT NOT NULL,
          target_kind TEXT NOT NULL,
          target_id TEXT NOT NULL,
          PRIMARY KEY (owner_kind, owner_id, target_kind, target_id)
        )
      ''')
      ..execute('CREATE INDEX link_target ON link (target_kind, target_id)')
      ..execute('CREATE TABLE rev (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)')
      ..insert('rev', {'id': 1, 'n': 0});
    await batch.commit(noResult: true);
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    await db?.close();
  }

  /// Every write goes through here: one transaction, and the mark moves.
  Future<T> _write<T>(Future<T> Function(DatabaseExecutor txn) body) async {
    final db = await _open();
    return db.transaction((txn) async {
      final out = await body(txn);
      await txn.rawUpdate('UPDATE rev SET n = n + 1 WHERE id = 1');
      return out;
    });
  }

  String newId() => _uuid.v4();

  // Places.

  Future<Place> createPlace({
    required String name,
    required PlaceKind kind,
    required double lat,
    required double lng,
    String? parentId,
    String country = '',
  }) async {
    final place = Place(
      id: newId(),
      name: name.trim(),
      kind: kind,
      lat: lat,
      lng: lng,
      parentId: parentId,
      country: country,
      createdAt: DateTime.now(),
    );
    await _write((txn) => txn.insert('place', _placeRow(place)));
    return place;
  }

  Future<void> updatePlace(Place place) => _write(
    (txn) => txn.update(
      'place',
      _placeRow(place),
      where: 'id = ?',
      whereArgs: [place.id],
    ),
  );

  /// False, and nothing removed, while entries, routes or points still use
  /// it: those are the user's writing.
  Future<bool> deletePlace(String id) async {
    if (await isPlaceInUse(id)) return false;
    await _write(
      (txn) => txn.delete('place', where: 'id = ?', whereArgs: [id]),
    );
    return true;
  }

  Future<bool> isPlaceInUse(String id) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT EXISTS (SELECT 1 FROM entry WHERE place_id = ?1) '
      'OR EXISTS (SELECT 1 FROM stop WHERE place_id = ?1) '
      'OR EXISTS (SELECT 1 FROM place WHERE parent_id = ?1) AS used',
      [id],
    );
    return rows.first['used'] == 1;
  }

  /// By name.
  Future<List<Place>> places() async {
    final db = await _open();
    final rows = await db.query('place', orderBy: 'name COLLATE NOCASE');
    return [for (final r in rows) _place(r)];
  }

  Future<Place?> place(String id) async {
    final db = await _open();
    final rows = await db.query('place', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _place(rows.first);
  }

  /// The points in a city, by name.
  Future<List<Place>> placesIn(String cityId) async {
    final db = await _open();
    final rows = await db.query(
      'place',
      where: 'parent_id = ?',
      whereArgs: [cityId],
      orderBy: 'name COLLATE NOCASE',
    );
    return [for (final r in rows) _place(r)];
  }

  /// The city called [name] in [country] (case-insensitive), made if there
  /// is none yet.
  Future<Place> findOrCreateCity({
    required String name,
    String country = '',
    required double lat,
    required double lng,
  }) async {
    final db = await _open();
    final rows = await db.query(
      'place',
      where:
          "kind = 'city' AND name = ? COLLATE NOCASE "
          'AND country = ? COLLATE NOCASE',
      whereArgs: [name.trim(), country],
      limit: 1,
    );
    if (rows.isNotEmpty) return _place(rows.first);
    return createPlace(
      name: name,
      kind: PlaceKind.city,
      lat: lat,
      lng: lng,
      country: country,
    );
  }

  /// Entries per place, by kind, in one query. Places without any are
  /// absent.
  Future<Map<String, PlaceEntryCounts>> entryCountsByPlace() async {
    final db = await _open();
    final rows = await db.rawQuery(
      "SELECT place_id, SUM(kind = 'diary') AS d, "
      "SUM(kind = 'impression') AS i FROM entry GROUP BY place_id",
    );
    return {
      for (final r in rows)
        r['place_id'] as String: PlaceEntryCounts(
          diary: r['d'] as int? ?? 0,
          impressions: r['i'] as int? ?? 0,
        ),
    };
  }

  // Entries.

  /// Inserts or replaces by [TravelEntry.id]; returns it as stored, with
  /// [TravelEntry.updatedAt] now. Use [newEntry] for a fresh one.
  Future<TravelEntry> saveEntry(TravelEntry entry) async {
    final stored = TravelEntry(
      id: entry.id,
      placeId: entry.placeId,
      kind: entry.kind,
      at: entry.at,
      title: entry.title,
      text: entry.text,
      rating: entry.kind == EntryKind.impression ? entry.rating : null,
      tags: entry.tags,
      createdAt: entry.createdAt,
      updatedAt: DateTime.now(),
    );
    await _write(
      (txn) => txn.insert(
        'entry',
        _entryRow(stored),
        conflictAlgorithm: ConflictAlgorithm.replace,
      ),
    );
    return stored;
  }

  /// Not stored until [saveEntry].
  TravelEntry newEntry({
    required String placeId,
    required EntryKind kind,
    DateTime? at,
  }) {
    final now = DateTime.now();
    return TravelEntry(
      id: newId(),
      placeId: placeId,
      kind: kind,
      at: at ?? DateTime(now.year, now.month, now.day),
      createdAt: now,
      updatedAt: now,
    );
  }

  /// With its links.
  Future<void> deleteEntry(String id) => _write((txn) async {
    await txn.delete('entry', where: 'id = ?', whereArgs: [id]);
    await _dropLinks(txn, LinkOwner.entry, id);
  });

  Future<TravelEntry?> entry(String id) async {
    final db = await _open();
    final rows = await db.query('entry', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _entry(rows.first);
  }

  static const _entryOrder = 'at IS NULL, at DESC, created_at DESC';

  /// Newest visit first, undated last.
  Future<List<TravelEntry>> entriesAt(String placeId, {EntryKind? kind}) async {
    final db = await _open();
    final rows = await db.query(
      'entry',
      where: kind == null ? 'place_id = ?' : 'place_id = ? AND kind = ?',
      whereArgs: [placeId, ?kind?.name],
      orderBy: _entryOrder,
    );
    return [for (final r in rows) _entry(r)];
  }

  /// Across all places, newest first.
  Future<List<TravelEntry>> entries({
    EntryKind? kind,
    int limit = 200,
    int offset = 0,
  }) async {
    final db = await _open();
    final rows = await db.query(
      'entry',
      where: kind == null ? null : 'kind = ?',
      whereArgs: kind == null ? null : [kind.name],
      orderBy: _entryOrder,
      limit: limit,
      offset: offset,
    );
    return [for (final r in rows) _entry(r)];
  }

  /// Entries a photo or person is linked to, newest first.
  Future<List<TravelEntry>> entriesLinkedTo(
    LinkTarget target,
    String id,
  ) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT e.* FROM entry e JOIN link l '
      "ON l.owner_kind = 'entry' AND l.owner_id = e.id "
      'WHERE l.target_kind = ? AND l.target_id = ? '
      'ORDER BY e.at IS NULL, e.at DESC, e.created_at DESC',
      [target.name, id],
    );
    return [for (final r in rows) _entry(r)];
  }

  // Routes.

  /// With no stops; add them with [setStops].
  Future<TravelRoute> createRoute({
    required String title,
    String note = '',
    DateTime? starts,
    DateTime? ends,
  }) async {
    final route = TravelRoute(
      id: newId(),
      title: title.trim(),
      note: note,
      starts: starts,
      ends: ends,
      createdAt: DateTime.now(),
    );
    await _write((txn) => txn.insert('route', _routeRow(route)));
    return route;
  }

  Future<void> updateRoute(TravelRoute route) => _write(
    (txn) => txn.update(
      'route',
      _routeRow(route),
      where: 'id = ?',
      whereArgs: [route.id],
    ),
  );

  /// With its stops, legs and links. The places stay.
  Future<void> deleteRoute(String id) => _write((txn) async {
    await txn.delete('route', where: 'id = ?', whereArgs: [id]);
    await txn.delete('stop', where: 'route_id = ?', whereArgs: [id]);
    await txn.delete('leg', where: 'route_id = ?', whereArgs: [id]);
    await _dropLinks(txn, LinkOwner.route, id);
  });

  /// Newest start first, undated last.
  Future<List<TravelRoute>> routes() async {
    final db = await _open();
    final rows = await db.query(
      'route',
      orderBy: 'starts IS NULL, starts DESC, created_at DESC',
    );
    return [for (final r in rows) _route(r)];
  }

  /// Routes with a stop at [placeId], or at a point inside it.
  Future<List<TravelRoute>> routesThrough(String placeId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT * FROM route WHERE id IN (SELECT s.route_id FROM stop s '
      'JOIN place p ON p.id = s.place_id WHERE p.id = ?1 OR p.parent_id = ?1) '
      'ORDER BY starts IS NULL, starts DESC, created_at DESC',
      [placeId],
    );
    return [for (final r in rows) _route(r)];
  }

  Future<List<TravelRoute>> routesLinkedTo(LinkTarget target, String id) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT r.* FROM route r JOIN link l '
      "ON l.owner_kind = 'route' AND l.owner_id = r.id "
      'WHERE l.target_kind = ? AND l.target_id = ? '
      'ORDER BY r.starts IS NULL, r.starts DESC, r.created_at DESC',
      [target.name, id],
    );
    return [for (final r in rows) _route(r)];
  }

  /// The route, its stops and legs in order, and their places: four
  /// queries, none per stop.
  Future<RouteDetail?> routeDetail(String id) async {
    final db = await _open();
    final routeRows = await db.query('route', where: 'id = ?', whereArgs: [id]);
    if (routeRows.isEmpty) return null;
    final stopRows = await db.query(
      'stop',
      where: 'route_id = ?',
      whereArgs: [id],
      orderBy: 'position',
    );
    final legRows = await db.query(
      'leg',
      where: 'route_id = ?',
      whereArgs: [id],
      orderBy: 'position',
    );
    final placeRows = await db.rawQuery(
      'SELECT * FROM place WHERE id IN '
      '(SELECT place_id FROM stop WHERE route_id = ?)',
      [id],
    );
    final stops = [for (final r in stopRows) _stop(r)];
    final byPosition = {for (final r in legRows) r['position'] as int: r};
    return RouteDetail(
      route: _route(routeRows.first),
      stops: stops,
      legs: [
        for (var i = 0; i + 1 < stops.length; i++)
          byPosition[i] == null ? const RouteLeg() : _leg(byPosition[i]!),
      ],
      places: {for (final r in placeRows) r['id'] as String: _place(r)},
    );
  }

  /// Replaces the stops with [stops], in order, and rearranges the legs to
  /// match ([rearrangeLegs]): a leg between the same two places keeps its
  /// commentary; any other is kept and flagged for review, never dropped.
  /// Notes with no leg left to hold them are appended to the route's note.
  Future<void> setStops(String routeId, List<RouteStop> stops) =>
      _write((txn) async {
        final oldStops = [
          for (final r in await txn.query(
            'stop',
            where: 'route_id = ?',
            whereArgs: [routeId],
            orderBy: 'position',
          ))
            r['place_id'] as String,
        ];
        final legRows = await txn.query(
          'leg',
          where: 'route_id = ?',
          whereArgs: [routeId],
          orderBy: 'position',
        );
        final byPosition = {for (final r in legRows) r['position'] as int: r};
        final oldLegs = [
          for (var i = 0; i + 1 < oldStops.length; i++)
            byPosition[i] == null ? const RouteLeg() : _leg(byPosition[i]!),
        ];
        final next = [for (final s in stops) s.placeId];
        final (:legs, :orphanNotes) = rearrangeLegs(oldStops, oldLegs, next);
        await txn.delete('stop', where: 'route_id = ?', whereArgs: [routeId]);
        await txn.delete('leg', where: 'route_id = ?', whereArgs: [routeId]);
        final batch = txn.batch();
        for (final (i, s) in stops.indexed) {
          batch.insert('stop', {
            'route_id': routeId,
            'position': i,
            'place_id': s.placeId,
            'arrived': s.arrived?.millisecondsSinceEpoch,
            'note': s.note,
          });
        }
        for (final (i, l) in legs.indexed) {
          batch.insert('leg', _legRow(routeId, i, l, next[i], next[i + 1]));
        }
        await batch.commit(noResult: true);
        if (orphanNotes.isNotEmpty) {
          final rows = await txn.query(
            'route',
            columns: ['note'],
            where: 'id = ?',
            whereArgs: [routeId],
          );
          if (rows.isNotEmpty) {
            final note = [
              rows.first['note'] as String,
              ...orphanNotes,
            ].where((n) => n.isNotEmpty).join('\n\n');
            await txn.update(
              'route',
              {'note': note},
              where: 'id = ?',
              whereArgs: [routeId],
            );
          }
        }
      });

  /// One stop's date or note; its place changes through [setStops].
  Future<void> saveStop(String routeId, int position, RouteStop stop) => _write(
    (txn) => txn.update(
      'stop',
      {'arrived': stop.arrived?.millisecondsSinceEpoch, 'note': stop.note},
      where: 'route_id = ? AND position = ?',
      whereArgs: [routeId, position],
    ),
  );

  /// The leg from stop [position] to the next. Saving it clears its
  /// review flag unless [leg] still carries it.
  Future<void> saveLeg(String routeId, int position, RouteLeg leg) =>
      _write((txn) async {
        final ends = await txn.query(
          'stop',
          columns: ['position', 'place_id'],
          where: 'route_id = ? AND position IN (?, ?)',
          whereArgs: [routeId, position, position + 1],
          orderBy: 'position',
        );
        if (ends.length < 2) return;
        await txn.insert(
          'leg',
          _legRow(
            routeId,
            position,
            leg,
            ends[0]['place_id'] as String,
            ends[1]['place_id'] as String,
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });

  // Links.

  /// Replaces [owner] [ownerId]'s links with [links], in one batch.
  Future<void> setLinks(
    LinkOwner owner,
    String ownerId,
    Iterable<TravelLink> links,
  ) => _write((txn) async {
    await _dropLinks(txn, owner, ownerId);
    final batch = txn.batch();
    for (final l in links.toSet()) {
      batch.insert('link', {
        'owner_kind': owner.name,
        'owner_id': ownerId,
        'target_kind': l.target.name,
        'target_id': l.id,
      });
    }
    await batch.commit(noResult: true);
  });

  /// Links of every owner in [ownerIds], grouped by owner; owners without
  /// any are absent. One query per 500 owners.
  Future<Map<String, List<TravelLink>>> linksFor(
    LinkOwner owner,
    Iterable<String> ownerIds,
  ) async {
    final db = await _open();
    final ids = ownerIds.toSet().toList();
    final out = <String, List<TravelLink>>{};
    for (var i = 0; i < ids.length; i += _chunk) {
      final part = ids.sublist(
        i,
        i + _chunk > ids.length ? ids.length : i + _chunk,
      );
      final rows = await db.query(
        'link',
        where:
            'owner_kind = ? AND owner_id IN '
            '(${List.filled(part.length, '?').join(',')})',
        whereArgs: [owner.name, ...part],
        orderBy: 'rowid',
      );
      for (final r in rows) {
        (out[r['owner_id'] as String] ??= []).add(
          TravelLink(LinkTarget.of(r['target_kind']), r['target_id'] as String),
        );
      }
    }
    return out;
  }

  /// Two people merged into one.
  Future<void> movePerson(String from, String to) => _write(
    (txn) => txn
        .rawUpdate(
          "UPDATE OR IGNORE link SET target_id = ? "
          "WHERE target_kind = 'person' AND target_id = ?",
          [to, from],
        )
        .then(
          (_) => txn.delete(
            'link',
            where: "target_kind = 'person' AND target_id = ?",
            whereArgs: [from],
          ),
        ),
  );

  /// A person deleted: the entries and routes stay, without them.
  Future<void> forgetPerson(String personId) => _write(
    (txn) => txn.delete(
      'link',
      where: "target_kind = 'person' AND target_id = ?",
      whereArgs: [personId],
    ),
  );

  // Backup.

  /// A consistent copy at [dest].
  Future<bool> copyTo(String dest) async =>
      copyDatabase(await _open(), _factory, dest);

  /// Rows of a backed-up copy at [path] added here; a row already here
  /// keeps what it has.
  Future<int> mergeFrom(String path) async {
    final added = await mergeDatabase(await _open(), path);
    if (added > 0) {
      await _write((_) async {});
    }
    return added;
  }

  /// Moves on every write, edits included.
  Future<int> dataMark() async {
    final db = await _open();
    final rev = await db.rawQuery('SELECT n FROM rev WHERE id = 1');
    return await tablesMark(db, _tables) + (rev.first['n'] as int? ?? 0);
  }

  // Rows.

  static Future<void> _dropLinks(
    DatabaseExecutor txn,
    LinkOwner owner,
    String id,
  ) => txn.delete(
    'link',
    where: 'owner_kind = ? AND owner_id = ?',
    whereArgs: [owner.name, id],
  );

  static int? _ms(DateTime? t) => t?.millisecondsSinceEpoch;
  static DateTime? _time(Object? ms) =>
      ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;

  static Map<String, Object?> _placeRow(Place p) => {
    'id': p.id,
    'name': p.name,
    'kind': p.kind.name,
    'lat': p.lat,
    'lng': p.lng,
    'parent_id': p.parentId,
    'country': p.country,
    'created_at': p.createdAt.millisecondsSinceEpoch,
  };

  static Place _place(Map<String, Object?> r) => Place(
    id: r['id'] as String,
    name: r['name'] as String,
    kind: PlaceKind.of(r['kind']),
    lat: (r['lat'] as num).toDouble(),
    lng: (r['lng'] as num).toDouble(),
    parentId: r['parent_id'] as String?,
    country: r['country'] as String? ?? '',
    createdAt: _time(r['created_at'])!,
  );

  static Map<String, Object?> _entryRow(TravelEntry e) => {
    'id': e.id,
    'place_id': e.placeId,
    'kind': e.kind.name,
    'at': _ms(e.at),
    'title': e.title,
    'text': e.text,
    'rating': e.rating,
    'tags': jsonEncode(e.tags),
    'created_at': e.createdAt.millisecondsSinceEpoch,
    'updated_at': e.updatedAt.millisecondsSinceEpoch,
  };

  static TravelEntry _entry(Map<String, Object?> r) => TravelEntry(
    id: r['id'] as String,
    placeId: r['place_id'] as String,
    kind: EntryKind.of(r['kind']),
    at: _time(r['at']),
    title: r['title'] as String? ?? '',
    text: r['text'] as String? ?? '',
    rating: r['rating'] as int?,
    tags: _tags(r['tags']),
    createdAt: _time(r['created_at'])!,
    updatedAt: _time(r['updated_at'])!,
  );

  static List<String> _tags(Object? json) {
    if (json is! String) return const [];
    try {
      final list = jsonDecode(json);
      return list is List
          ? [for (final t in list) ?(t is String ? t : null)]
          : const [];
    } on FormatException {
      return const [];
    }
  }

  static Map<String, Object?> _routeRow(TravelRoute r) => {
    'id': r.id,
    'title': r.title,
    'note': r.note,
    'starts': _ms(r.starts),
    'ends': _ms(r.ends),
    'created_at': r.createdAt.millisecondsSinceEpoch,
  };

  static TravelRoute _route(Map<String, Object?> r) => TravelRoute(
    id: r['id'] as String,
    title: r['title'] as String,
    note: r['note'] as String? ?? '',
    starts: _time(r['starts']),
    ends: _time(r['ends']),
    createdAt: _time(r['created_at'])!,
  );

  static RouteStop _stop(Map<String, Object?> r) => RouteStop(
    placeId: r['place_id'] as String,
    arrived: _time(r['arrived']),
    note: r['note'] as String? ?? '',
  );

  static Map<String, Object?> _legRow(
    String routeId,
    int position,
    RouteLeg l,
    String from,
    String to,
  ) => {
    'route_id': routeId,
    'position': position,
    'mode': l.mode.name,
    'note': l.note,
    'from_place': from,
    'to_place': to,
    'needs_review': l.needsReview ? 1 : 0,
  };

  static RouteLeg _leg(Map<String, Object?> r) => RouteLeg(
    mode: LegMode.of(r['mode']),
    note: r['note'] as String? ?? '',
    needsReview: r['needs_review'] == 1,
  );
}
