import 'dart:convert';

import 'op.dart';

/// An op before it is stamped: what a local edit wants to say.
class Change {
  const Change(this.e, this.id, this.o, {this.f, this.x, this.ts = const []});
  final String e;
  final String id;
  final OpKind o;
  final String? f;
  final Object? x;

  /// For `mrem`: filled at sealing from the tags this device has seen.
  final List<String> ts;

  @override
  String toString() => '$e/$id ${o.name} ${f ?? ''} ${jsonEncode(x)}';
}

/// `asset_record` columns that are LWW fields of the same name.
const assetFields = {
  'description',
  'location',
  'latitude',
  'longitude',
  'is_favorite',
  'is_archived',
  'deleted_at',
  'created_at',
  'original_key',
  'thumbnail_key',
  'medium_key',
  'live_key',
  'edited_key',
};

/// Only on `add`: fixed for the photo's life.
const assetAddOnly = {
  'content_hash',
  // SHA-256 of the uploaded original: how a browser upload spots a photo
  // already here (a camera-roll record's content_hash is its asset id).
  'original_hash',
  'is_video',
  'is_live_photo',
  'width',
  'height',
};

const albumFields = {'name', 'description', 'cover_local_id'};
const personFields = {
  'name',
  'bio',
  'birth_date',
  'gender',
  'avatar_local_id',
  'avatar_face',
  'first_name',
  'middle_name',
  'last_name',
  'custom_fields',
  'ignored',
};

/// Marks a person whose profile rows ([profileSets], `details`) are in the
/// log. Until a phone has sent them, the applier leaves its rows alone: an
/// empty set there means "never sent", not "all removed".
const profileMarker = 'profile';

/// A person's open profile rows, per table: the set they ride in and the
/// columns that make one member. Rows behind a passcode never leave.
const profileSets = {
  'person_event': ('events', ['id', 'at', 'type', 'tags', 'notes']),
  'person_location': ('places', ['id', 'kind', 'place', 'since']),
  'person_known_as': ('known_as', ['kind', 'key', 'value', 'added_at']),
  'person_alias': ('aliases', ['alias_id']),
  'person_group': ('groups', ['group_id', 'name', 'kind']),
  'person_relationship': (
    'relations',
    ['related_person_id', 'type', 'organization', 'created_at'],
  ),
};

/// One profile row as its set member: the same JSON from the same row on
/// every phone, so a removal names exactly what was added.
String profileMember(String table, Map<String, Object?> row) {
  final cols = profileSets[table]!.$2;
  if (cols.length == 1) return '${row[cols.single]}';
  return jsonEncode({for (final c in cols) c: row[c]});
}

/// Columns the capture triggers record, per table.
const assetCaptureColumns = [
  ...assetFields,
  ...assetAddOnly,
  'tags',
  'original_status',
];
const albumCaptureColumns = [...albumFields, 'tags', 'is_demo'];
const personCaptureColumns = [...personFields, 'is_demo'];

/// `travel.db` columns that are LWW fields of the same name.
const placeFields = {
  'name',
  'kind',
  'lat',
  'lng',
  'parent_id',
  'country',
  'address',
  'category',
  'description',
  'created_at',
};
const entryFields = {
  'place_id',
  'kind',
  'at',
  'title',
  'text',
  'rating',
  'created_at',
};
const routeFields = {'title', 'note', 'starts', 'ends', 'created_at'};
const entryCaptureColumns = [...entryFields, 'tags'];

/// A route's whole stop list as JSON, each stop with the leg to the next:
/// `[{place, arrived, note, mode, leg, review}]`. SQL on the route id.
String routeStopsSql(String routeId) =>
    '(SELECT json_group_array(json(j)) FROM (SELECT json_object('
    "'place', s.place_id, 'arrived', s.arrived, 'note', s.note, "
    "'mode', l.mode, 'leg', l.note, 'review', l.needs_review) AS j "
    'FROM stop s LEFT JOIN leg l '
    'ON l.route_id = s.route_id AND l.position = s.position '
    'WHERE s.route_id = $routeId ORDER BY s.position))';

/// A `link` row's key: `<owner kind>/<owner id>/<target kind>/<target id>`.
const linkKeySql =
    "{row}.owner_kind || '/' || {row}.owner_id || '/' || "
    "{row}.target_kind || '/' || {row}.target_id";

/// Set names for link targets.
const linkSets = {'asset': 'photos', 'person': 'people'};

/// One captured write → the ops it means. [now] stamps purges and bins.
///
/// - A photo enters the log once its original is in the bucket (`add`
///   with everything it has by then); edits before that ride in the `add`.
/// - A row turning private sends `hidden: true` and nothing else; back to
///   open re-sends the whole row.
/// - A deleted photo record is `purged`; a deleted album or person is binned.
List<Change> translate(
  String table,
  String key,
  String kind,
  Map<String, Object?>? before,
  Map<String, Object?>? after,
  int now,
) {
  switch (table) {
    case 'asset_record':
      return _asset(key, kind, before, after, now);
    case 'album':
      return _owner('album', key, kind, before, after, albumFields, now);
    case 'person':
      return _owner('person', key, kind, before, after, personFields, now);
    case 'person_detail':
      return [
        Change(
          'person',
          key,
          OpKind.set,
          f: 'details',
          x: kind == 'delete' || _private(after) ? null : after?['payload'],
        ),
      ];
    case final t when profileSets.containsKey(t):
      final set = profileSets[t]!.$1;
      final was = before == null || _private(before)
          ? null
          : profileMember(t, before);
      final now = after == null || _private(after)
          ? null
          : profileMember(t, after);
      if (was == now) return const [];
      return [
        if (was != null) Change('person', key, OpKind.mrem, f: set, x: was),
        if (now != null) Change('person', key, OpKind.madd, f: set, x: now),
      ];
    case 'album_asset':
    case 'person_asset':
      final slash = key.indexOf('/');
      final owner = key.substring(0, slash);
      final asset = key.substring(slash + 1);
      final e = table == 'album_asset' ? 'album' : 'person';
      return [
        if (kind == 'insert')
          Change(e, owner, OpKind.madd, f: 'members', x: asset),
        if (kind == 'delete')
          Change(e, owner, OpKind.mrem, f: 'members', x: asset),
      ];
    case 'place':
      return _owner('place', key, kind, before, after, placeFields, now);
    case 'entry':
      return _owner('entry', key, kind, before, after, entryFields, now);
    case 'route':
      return _owner('route', key, kind, before, after, routeFields, now);
    case 'stop':
    case 'leg':
      final stops = (after ?? before)?['stops'];
      return [
        Change(
          'route',
          key,
          OpKind.set,
          f: 'stops',
          x: stops is String ? stops : jsonEncode(stops ?? const []),
        ),
      ];
    case 'link':
      final parts = key.split('/');
      if (parts.length < 4) return const [];
      final set = linkSets[parts[2]];
      if (set == null) return const [];
      final member = parts.sublist(3).join('/');
      return [
        if (kind == 'insert')
          Change(parts[0], parts[1], OpKind.madd, f: set, x: member),
        if (kind == 'delete')
          Change(parts[0], parts[1], OpKind.mrem, f: set, x: member),
      ];
  }
  return const [];
}

bool _private(Map<String, Object?>? row) =>
    row != null && (row['_private'] == 1 || row['_private'] == true);

List<String> _tags(Map<String, Object?>? row) {
  final raw = row?['tags'];
  if (raw is! String || raw.isEmpty) return const [];
  try {
    return [...(jsonDecode(raw) as List).whereType<String>()];
  } catch (_) {
    return const [];
  }
}

List<Change> _tagDiff(
  String e,
  String id,
  List<String> was,
  List<String> now,
) => [
  for (final t in now.toSet().difference(was.toSet()))
    Change(e, id, OpKind.madd, f: 'tags', x: t),
  for (final t in was.toSet().difference(now.toSet()))
    Change(e, id, OpKind.mrem, f: 'tags', x: t),
];

List<Change> _asset(
  String id,
  String kind,
  Map<String, Object?>? before,
  Map<String, Object?>? after,
  int now,
) {
  bool uploaded(Map<String, Object?>? r) =>
      r != null && r['original_status'] == 'uploaded';
  if (kind == 'delete') {
    if (!uploaded(before) || _private(before)) return const [];
    return [Change('asset', id, OpKind.set, f: 'purged', x: now)];
  }
  final row = after!;
  if (!uploaded(row)) return const [];
  if (_private(row)) {
    return _private(before) || !uploaded(before)
        ? const []
        : [Change('asset', id, OpKind.set, f: 'hidden', x: true)];
  }
  final wasShared = uploaded(before) && !_private(before);
  if (!wasShared) {
    return [
      Change(
        'asset',
        id,
        OpKind.add,
        x: {
          for (final f in assetFields) f: row[f],
          for (final c in assetAddOnly) c: row[c],
          if (_private(before)) 'hidden': false,
        },
      ),
      for (final t in _tags(row))
        Change('asset', id, OpKind.madd, f: 'tags', x: t),
    ];
  }
  return [
    for (final f in assetFields)
      if (before![f] != row[f])
        Change('asset', id, OpKind.set, f: f, x: row[f]),
    ..._tagDiff('asset', id, _tags(before), _tags(row)),
  ];
}

List<Change> _owner(
  String e,
  String id,
  String kind,
  Map<String, Object?>? before,
  Map<String, Object?>? after,
  Set<String> fields,
  int now,
) {
  if ((after ?? before)?['is_demo'] == 1) return const [];
  if (kind == 'delete') {
    return _private(before)
        ? const []
        : [Change(e, id, OpKind.set, f: 'deleted_at', x: now)];
  }
  final row = after!;
  if (_private(row)) {
    return before == null || _private(before)
        ? const []
        : [Change(e, id, OpKind.set, f: 'hidden', x: true)];
  }
  if (kind == 'insert' || _private(before)) {
    return [
      Change(
        e,
        id,
        OpKind.add,
        x: {
          for (final f in fields) f: row[f],
          'deleted_at': null,
          if (_private(before)) 'hidden': false,
          if (e == 'person' && kind == 'insert') profileMarker: 1,
        },
      ),
      for (final t in _tags(row)) Change(e, id, OpKind.madd, f: 'tags', x: t),
    ];
  }
  return [
    for (final f in fields)
      if (before![f] != row[f]) Change(e, id, OpKind.set, f: f, x: row[f]),
    ..._tagDiff(e, id, _tags(before), _tags(row)),
  ];
}
