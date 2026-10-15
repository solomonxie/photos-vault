import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/vault/hidden_repair.dart';
import 'package:photos_vault/vault/object_key.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  final taken = DateTime(2026, 10, 6, 16, 28, 2);
  // A keyed decoy date, years from the photo's own.
  const hiddenStem = '20250616032353_1237bd5a00000000000000000000aaaa';
  const resent = '20180114044141_94eb9f0000000000000000000000bbbb';

  Future<FakeAssetRecordStore> library() async {
    final store = FakeAssetRecordStore();
    Future<void> row(
      String id, {
      String? original,
      String? held,
      String? hash,
      DateTime? at,
    }) async {
      await store.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        createdAt: at ?? taken,
      );
      if (hash != null) await store.setPasscodeHash(id, hash);
      if (original != null) {
        await store.updateDerivative(
          id,
          DerivativeKind.original,
          DerivativeState(
            status: UploadStatus.uploaded,
            destinationKey: original,
          ),
        );
      }
      if (held != null) {
        await store.recordUpload(
          localId: id,
          kind: DerivativeKind.original,
          targetId: 't1',
          destinationKey: held,
        );
      }
    }

    // Un-hidden by an old build: its original is under the carrier name.
    await row(
      'photo:EA10C64A/L0/001',
      original: 'p/originals/$hiddenStem.jpg',
      held: 'p/originals/$hiddenStem.jpg',
    );
    // Its own name, and its own name on another date.
    final own = ordinaryNameHash('photo:own');
    await row('photo:own', original: 'p/originals/20200101000000_$own.jpg');
    // Another phone's name, shared with the import of that object.
    final shared = '20261002220027_${'d' * 32}';
    await row(
      'photo:twin',
      original: 'p/originals/$shared.jpg',
      at: DateTime(2026, 7, 5),
    );
    await row('bucket:$shared', original: 'p/originals/$shared.jpg');
    // A re-encode under some other install's name: never a carrier's
    // extension.
    await row(
      'photo:webp',
      original: 'p/originals/20261002220027_${'9' * 32}.webp',
      at: DateTime(2026, 7, 5),
    );
    // An adopted filed photo, re-sent under a second carrier.
    final filed = '20150903064804_${'f' * 32}';
    await row(
      'manual:vault-$filed',
      original: 'originals/$filed.jpg',
      held: 'p/originals/$resent.jpg',
      hash: 'h',
    );
    // One adopted cleanly.
    final clean = '20120808114420_${'e' * 32}';
    await row(
      'manual:vault-$clean',
      original: 'originals/$clean.jpg',
      held: 'p/originals/$clean.jpg',
      hash: 'h',
    );
    // A hidden photo's own carrier is not suspect.
    await row('photo:hidden', original: 'p/originals/$resent.mov', hash: 'h');
    return store;
  }

  test('lists the carrier-named photo and the two-carrier adoption, '
      'nothing else', () async {
    final store = await library();

    final found = await HiddenRepair(store: store).runOnce();

    expect(
      {for (final f in found) f.localId: f.kind},
      {
        'photo:EA10C64A/L0/001': RepairKind.carrierStem,
        'manual:vault-20150903064804_${'f' * 32}': RepairKind.twoCarriers,
      },
    );
    expect(
      found.singleWhere((f) => f.kind == RepairKind.twoCarriers).hidden,
      isTrue,
      reason: 'shown behind the code only',
    );
  });

  test('changes nothing, deletes nothing, and runs once', () async {
    final store = await library();
    final before = {
      for (final r in await store.listAll()) r.localId: r.derivatives,
    };
    final holdings = await store.allHoldings();

    final first = await HiddenRepair(store: store).runOnce();

    expect(await PendingDeletes(store: store).pending(), isEmpty);
    expect(await DeferredDeletes(store: store).waiting(), isEmpty);
    expect(await store.allHoldings(), holdings);
    for (final r in await store.listAll()) {
      expect(r.derivatives, before[r.localId], reason: r.localId);
    }

    // A later change is not rescanned: the list is what was found then.
    await store.remove('photo:EA10C64A/L0/001');
    final again = await HiddenRepair(store: store).runOnce();
    expect(again.map((f) => f.localId), first.map((f) => f.localId));
  });
}
