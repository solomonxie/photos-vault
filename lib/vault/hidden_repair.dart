import 'dart:convert';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'hidden_transition.dart';
import 'object_key.dart';

enum RepairKind {
  /// An ordinary photo whose bucket key has a name that is neither its own
  /// nor any other photo's: the carrier it was hidden under, which an
  /// un-hide may have uploaded the plain photo over (03#9b).
  carrierStem,

  /// A filed photo an earlier build adopted, with a second carrier under
  /// another name (03#6).
  twoCarriers,
}

class RepairItem {
  const RepairItem(this.localId, this.kind, {required this.hidden});

  final String localId;
  final RepairKind kind;

  /// Shown only inside its album, never in Flagged Items.
  final bool hidden;

  Map<String, Object?> toJson() => {
    'l': localId,
    'k': kind.name,
    if (hidden) 'h': true,
  };

  static RepairItem? fromJson(Map<String, dynamic> json) {
    final kind = RepairKind.values.asNameMap()[json['k']];
    if (kind == null) return null;
    return RepairItem(json['l'] as String, kind, hidden: json['h'] == true);
  }
}

/// A one-time look for what earlier builds left in the bucket that only
/// the user can decide about. **Lists, never changes**: nothing is
/// deleted, renamed, re-uploaded or reset. The list is kept in app state
/// and shown as information.
class HiddenRepair {
  HiddenRepair({required this.store});

  final AssetRecordStore store;

  static const stateKey = 'hidden_repair_v1';

  /// Scans once ever; after that, what that scan found.
  Future<List<RepairItem>> runOnce() async {
    final known = await findings();
    if (known != null) return known;
    final records = await store.listAll();
    final holdings = await store.allHoldings();
    final rows = [
      for (final r in records)
        (
          id: r.localId,
          hidden: r.passcodeHash != null,
          adopted: isAdopted(r),
          createdAt: r.createdAt,
          keys: [
            for (final kind in DerivativeKind.values)
              ?r.stateOf(kind).destinationKey,
          ],
          held: holdings[r.localId] ?? const {},
        ),
    ];
    final found = await Isolate.run(() => findRepairs(rows));
    await store.setAppState(
      stateKey,
      jsonEncode([for (final f in found) f.toJson()]),
    );
    return found;
  }

  /// Null until [runOnce] has run.
  Future<List<RepairItem>?> findings() async {
    final raw = await store.getAppState(stateKey);
    if (raw == null) return null;
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          ?RepairItem.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }
}

typedef RepairRow = ({
  String id,
  bool hidden,
  bool adopted,
  DateTime createdAt,
  List<String> keys,
  Map<DerivativeKind, Map<String, String>> held,
});

/// Pure, so it runs off the UI isolate: one hash per record.
List<RepairItem> findRepairs(List<RepairRow> rows) {
  const hexOf = ordinaryNameHash;
  final ordinary = {for (final r in rows) hexOf(r.id)};
  // Which records name each stem: one named by two photos is shared, not
  // a carrier's.
  final namedBy = <String, Set<String>>{};
  Iterable<String> allKeys(RepairRow r) => {
    ...r.keys,
    for (final byTarget in r.held.values) ...byTarget.values,
  };
  for (final r in rows) {
    for (final key in allKeys(r)) {
      (namedBy[_stem(key)] ??= {}).add(r.id);
    }
  }
  final out = <RepairItem>[];
  for (final r in rows) {
    if (!r.hidden) {
      final own = hexOf(r.id);
      final suspect = allKeys(r).any((key) {
        final stem = _stem(key);
        if (!fitsProtocol(stem)) return false;
        // A carrier is only ever written as one of these
        // (`CarrierBuilder`); a `.webp` or `.heif` is an ordinary upload.
        if (!const {'.jpg', '.mov'}.contains(p.posix.extension(key))) {
          return false;
        }
        final hex = stem.substring(15);
        if (hex == own || ordinary.contains(hex)) return false;
        if (r.id == 'bucket:$stem') return false;
        if ((namedBy[stem] ?? const {}).length > 1) return false;
        final stamped = parseObjectStamp(stem.substring(0, 14));
        // An ordinary name carries the photo's own date; a hidden one a
        // keyed, arbitrary one.
        if (stamped != null &&
            stamped.difference(r.createdAt).abs() <= const Duration(days: 1)) {
          return false;
        }
        return true;
      });
      if (suspect) {
        out.add(RepairItem(r.id, RepairKind.carrierStem, hidden: false));
      }
    }
    if (r.adopted) {
      final filed = {
        for (final key in r.keys)
          if (key.contains('originals/')) _stem(key),
      };
      final sent = {
        for (final key
            in r.held[DerivativeKind.original]?.values ?? const <String>[])
          _stem(key),
      };
      if (sent.difference(filed).isNotEmpty && filed.isNotEmpty) {
        out.add(RepairItem(r.id, RepairKind.twoCarriers, hidden: r.hidden));
      }
    }
  }
  return out;
}

String _stem(String key) => p.posix.basenameWithoutExtension(key);
