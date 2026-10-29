import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ego_net.dart';
import '../photos/person.dart';
import '../storage/asset_record_store.dart';
import 'fold_toggle.dart';
import 'person_avatar.dart';
import 'profile_section.dart';
import '../photos/name_sound.dart';

/// Above this many, the section gets a search field and type filters.
const relationshipSearchFrom = 20;

/// [relationships] closest first — see [compareTies].
List<PersonRelationship> rankRelationships(
  List<PersonRelationship> relationships,
  Map<String, int> sharedPhotos,
  Map<String, String> names,
) {
  EgoTie tie(PersonRelationship r) => EgoTie(
    personId: r.relatedPersonId,
    type: r.type,
    explicit: !r.derived,
    sharedPhotos: sharedPhotos[r.relatedPersonId] ?? 0,
  );
  final ties = {for (final r in relationships) r: tie(r)};
  return [...relationships]
    ..sort((a, b) => compareTies(ties[a]!, ties[b]!, names));
}

/// The typed links, by type, five each until opened; a search and type
/// filters once there are many. Slivers, so a thousand opened rows build
/// as they scroll in.
class ProfileRelationships extends StatefulWidget {
  const ProfileRelationships({
    super.key,
    required this.relationships,
    required this.people,
    required this.sharedPhotos,
    required this.assetRecordStore,
    required this.editing,
    required this.typeLabel,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  /// Drawn links only; group ones are rows of their own in Groups.
  final List<PersonRelationship> relationships;
  final Map<String, Person> people;
  final Map<String, int> sharedPhotos;
  final AssetRecordStore assetRecordStore;
  final bool editing;
  final String Function(RelationshipType) typeLabel;
  final ValueChanged<PersonRelationship> onOpen;
  final ValueChanged<PersonRelationship> onEdit;
  final ValueChanged<PersonRelationship> onDelete;

  @override
  State<ProfileRelationships> createState() => _ProfileRelationshipsState();
}

class _ProfileRelationshipsState extends State<ProfileRelationships> {
  final _expanded = <RelationshipType>{};
  final _search = TextEditingController();
  RelationshipType? _filter;
  late List<PersonRelationship> _ranked;
  late Map<RelationshipType, List<PersonRelationship>> _byType;

  @override
  void initState() {
    super.initState();
    _rank();
  }

  @override
  void didUpdateWidget(ProfileRelationships old) {
    super.didUpdateWidget(old);
    if (!identical(old.relationships, widget.relationships) ||
        !identical(old.sharedPhotos, widget.sharedPhotos) ||
        !identical(old.people, widget.people)) {
      _rank();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _rank() {
    _ranked = rankRelationships(widget.relationships, widget.sharedPhotos, {
      for (final MapEntry(:key, :value) in widget.people.entries)
        key: value.name,
    });
    _byType = {};
    for (final r in _ranked) {
      (_byType[r.type] ??= []).add(r);
    }
  }

  String _name(PersonRelationship r) =>
      widget.people[r.relatedPersonId]?.name ?? '?';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = _search.text.trim().toLowerCase();
    final searching = query.isNotEmpty || _filter != null;
    final slivers = <Widget>[
      if (_ranked.length > relationshipSearchFrom)
        SliverToBoxAdapter(child: _searchBar(l10n)),
    ];
    if (searching) {
      final hits = searchByName(
        [
          for (final r in _ranked)
            if (_filter == null || r.type == _filter) r,
        ],
        query,
        _name,
      );
      slivers.add(_rows(hits));
      if (hits.isEmpty) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.peopleSearchEmpty,
                style: const TextStyle(color: CupertinoColors.systemGrey),
              ),
            ),
          ),
        );
      }
    } else {
      for (final type in RelationshipType.values) {
        final all = _byType[type];
        if (all == null) continue;
        final open = _expanded.contains(type) || all.length <= foldedCount;
        slivers
          ..add(
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  widget.typeLabel(type),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
              ),
            ),
          )
          ..add(_rows(open ? all : all.sublist(0, foldedCount)));
        if (all.length > foldedCount) {
          slivers.add(
            SliverToBoxAdapter(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FoldToggle(
                  total: all.length,
                  expanded: _expanded.contains(type),
                  onPressed: () => setState(() {
                    if (!_expanded.remove(type)) _expanded.add(type);
                  }),
                ),
              ),
            ),
          );
        }
      }
    }
    return SliverMainAxisGroup(slivers: slivers);
  }

  Widget _searchBar(AppLocalizations l10n) {
    final types = [
      for (final t in RelationshipType.values)
        if (_byType.containsKey(t)) t,
    ];
    Widget chip(String label, RelationshipType? type) {
      final on = _filter == type;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: () => setState(() => _filter = type),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: on
                  ? CupertinoColors.activeBlue
                  : CupertinoColors.systemGrey.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: on ? CupertinoColors.white : CupertinoColors.systemGrey,
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: CupertinoSearchTextField(
            key: const ValueKey('relationshipSearch'),
            controller: _search,
            placeholder: l10n.profileRelationshipsSearch(_ranked.length),
            onChanged: (_) => setState(() {}),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(
            children: [
              chip(l10n.wordsAll, null),
              for (final t in types)
                chip('${widget.typeLabel(t)} ${_byType[t]!.length}', t),
            ],
          ),
        ),
      ],
    );
  }

  /// [rows] as one card, built as they scroll in.
  Widget _rows(List<PersonRelationship> rows) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    sliver: SliverList.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) => _CardSlice(
        first: i == 0,
        last: i == rows.length - 1,
        child: _row(rows[i]),
      ),
    ),
  );

  Widget _row(PersonRelationship r) {
    final person = widget.people[r.relatedPersonId];
    final org = r.organization;
    return ProfileDeletableRow(
      key: ValueKey('rel:${r.relatedPersonId}'),
      editing: widget.editing,
      onDelete: () => widget.onDelete(r),
      child: CupertinoListTile(
        leading: person == null
            ? null
            : PersonAvatar.forPerson(
                assetRecordStore: widget.assetRecordStore,
                person: person,
                size: 32,
              ),
        leadingSize: 32,
        title: Text(_name(r)),
        subtitle: org == null || org.isEmpty ? null : Text(org),
        trailing: widget.editing
            ? const Icon(
                CupertinoIcons.pencil,
                size: 18,
                color: CupertinoColors.systemGrey,
              )
            : const Icon(
                CupertinoIcons.chevron_forward,
                size: 18,
                color: CupertinoColors.systemGrey2,
              ),
        onTap: () => widget.editing ? widget.onEdit(r) : widget.onOpen(r),
      ),
    );
  }
}

/// One row of a card drawn row by row: rounded only at its ends, a hairline
/// between.
class _CardSlice extends StatelessWidget {
  const _CardSlice({
    required this.first,
    required this.last,
    required this.child,
  });

  final bool first;
  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const r = Radius.circular(10);
    return ClipRRect(
      borderRadius: BorderRadius.vertical(
        top: first ? r : Radius.zero,
        bottom: last ? r : Radius.zero,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: profileCardDecoration.color,
          border: last
              ? null
              : const Border(
                  bottom: BorderSide(
                    color: CupertinoColors.separator,
                    width: 0.5,
                  ),
                ),
        ),
        child: child,
      ),
    );
  }
}
