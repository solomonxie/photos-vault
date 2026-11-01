import '../photos/person_store.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import 'keys.dart';
import 'passcode_tags.dart';

/// Puts every person's hidden folder under [digits] on the key ring and in
/// the keychain, so their photos back up from now on without each folder
/// being opened by hand. Only folders that hold photos. Returns how many.
///
/// A hidden photo goes up only while its folder's key is on hand; a zip
/// import hides thousands across hundreds of people at once, and opening
/// each of them one by one never happens.
Future<int> keepPeopleAlbums({
  required AssetRecordStore records,
  required PersonStore people,
  required VaultKeys keys,
  required String digits,
}) async {
  final key = await PasscodeTags(
    records: records,
    people: people,
    vaultKeys: keys,
  ).currentKey();
  if (key == null) return 0;
  final held = await records.passcodeHashes();
  if (held.isEmpty) return 0;
  final ids = {
    for (final p in await people.listAll()) p.id,
    ...await people.allAliasIds(),
  };
  var kept = 0;
  for (final id in ids) {
    final code = personAlbumCode(id, digits);
    final tag = passcodeTagWith(key, code);
    if (!held.contains(tag)) continue;
    if (await keys.unlockAlbum(code, tag) == null) continue;
    await keys.keepAlbum(tag);
    kept++;
  }
  return kept;
}
