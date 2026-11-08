import 'dart:convert';

import '../storage/asset_record_store.dart';
import 'object_key.dart';

/// Carriers a folder no longer counts, by [carrierIdentity]: ones whose
/// photo was carried into another folder ([HiddenCarry]), and ones every
/// bucket answered 404 for. They stay in the buckets; nothing here deletes.
/// Bookkeeping: lost with a restore, the next carry finds its own rows
/// again and fills it back in.
class RetiredCarriers {
  RetiredCarriers(this.store);

  final AssetRecordStore store;

  static const stateKey = 'hidden_retired_v1';

  Future<Set<String>> all() async {
    final raw = await store.getAppState(stateKey);
    if (raw == null) return {};
    try {
      return {...(jsonDecode(raw) as List).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  Future<void> add(Iterable<String> keys) async {
    final adding = keys.map(carrierIdentity).toSet();
    if (adding.isEmpty) return;
    final held = await all();
    if (held.containsAll(adding)) return;
    await store.setAppState(stateKey, jsonEncode([...held, ...adding]));
  }
}
