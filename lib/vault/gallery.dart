import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import 'album_index.dart';
import 'bucket.dart';
import 'cache.dart';
import 'carrier.dart';
import 'cipher.dart';
import 'jpeg_segments.dart';
import 'keys.dart';
import 'store.dart';

/// Draws hidden photos.
///
/// **This phone first, the bucket second.** A hidden photo's carrier is kept
/// in `VaultStore` (durable, out of the device backup), so an album opens,
/// scrolls and plays with no network and no bucket configured at all. The
/// bucket is the copy that survives losing the phone, and the only source
/// for a photo the user has deliberately sent back to it.
///
/// Where a tile's bytes come from, in order:
///
/// ```text
/// _memory            decoded, this session
///   ↓ miss
/// store thumbnail    the tile alone, kept for a bucket-only photo
///   ↓ miss
/// store carrier      first 64 KB of the local file, one seek
///   ↓ miss
/// cache              what a previous fetch left behind
///   ↓ miss
/// bucket             one ranged GET of the first 64 KB
/// ```
///
/// The thumbnail riding in the first 64 KB of the carrier is what makes both
/// ends of that cheap: a tile is a seek or one ranged GET, never a 2 MB read.
class VaultGallery {
  VaultGallery({
    required this.keys,
    VaultBucket? bucket,
    VaultCache? cache,
    VaultStore? store,
    VaultCipher? cipher,
  }) : _bucket = bucket ?? VaultBucket(),
       _cache = cache ?? VaultCache(),
       _store = store ?? VaultStore(),
       _cipher = cipher ?? PlatformCipher();

  final AlbumKeys keys;
  final VaultBucket _bucket;
  final VaultCache _cache;
  final VaultStore _store;
  final VaultCipher _cipher;

  /// The store, for the album screen: which photos are held in full here,
  /// what that costs, and sending one back to the bucket.
  VaultStore get store => _store;

  /// Decoded tiles for this session. Dropped when the album closes, along
  /// with everything else this screen knows.
  final Map<String, Uint8List> _memory = {};

  /// The album's listing — from the bucket when it answers, from the local
  /// mirror when it doesn't.
  ///
  /// The bucket is asked first because another device may have added to the
  /// album, and its answer is mirrored on the way past so the next offline
  /// open is current. A bucket that doesn't answer is **not** an empty
  /// album: falling through to the mirror is the difference between "no
  /// signal" and "everything is gone".
  Future<List<IndexEntry>> list() async {
    final remote = await _bucket.loadIndex();
    if (remote != null) {
      await _store.writeIndex(remote);
      return readSection(cipher: _cipher, keys: keys, index: remote);
    }
    final local = await _store.readIndex();
    if (local == null) return const [];
    return readSection(cipher: _cipher, keys: keys, index: local);
  }

  /// Which of [entries] this phone holds in full. The rest are in the bucket
  /// only, and draw from a kept thumbnail until one is downloaded.
  Future<Set<String>> localKeys(List<IndexEntry> entries) async {
    final held = <String>{};
    for (final entry in entries) {
      if (await _store.hasCarrier(keys, entry.objectKey)) {
        held.add(entry.objectKey);
      }
    }
    return held;
  }

  Future<Uint8List?> thumbnail(String objectKey) async {
    final held = _memory[objectKey];
    if (held != null) return held;

    // Kept on purpose for a photo whose full copy went back to the bucket.
    final kept = await _store.readThumbnail(keys, objectKey);
    if (kept != null) {
      _memory[objectKey] = kept;
      return kept;
    }

    // The local carrier's own first 64 KB. One seek, no network, and the
    // reason an album scrolls offline.
    final localPrefix = await _store.carrierPrefix(keys, objectKey);
    if (localPrefix != null) {
      final opened = _openPrefix(localPrefix);
      if (opened != null) {
        _memory[objectKey] = opened;
        return opened;
      }
    }

    final cached = await _cache.read(CachePool.thumbnail, keys, objectKey);
    if (cached != null) {
      _memory[objectKey] = cached;
      return cached;
    }

    final prefix = await _bucket.thumbnailPrefix(objectKey);
    if (prefix == null) return null;
    final payload = payloadOfPrefix(prefix);
    if (payload == null) return null;
    final opened = openThumbnail(
      cipher: _cipher,
      keys: keys.carrier,
      payloadPrefix: payload,
    );
    if (opened == null) return null;
    _memory[objectKey] = opened;
    await _cache.write(CachePool.thumbnail, keys, objectKey, opened);
    return opened;
  }

  /// The photo itself: the local carrier when this phone still holds one,
  /// then the disk cache, then the bucket.
  ///
  /// Nothing is written to the cache on the local path — the carrier *is*
  /// the local copy, and a decrypted second copy of it in Caches would be
  /// the same photo twice, one of them purgeable.
  Future<Uint8List?> original(IndexEntry entry) async {
    final local = await _store.readCarrier(keys, entry.objectKey);
    if (local != null) {
      final payload = payloadOf(local);
      final opened = payload == null
          ? null
          : openCarrier(cipher: _cipher, keys: keys.carrier, payload: payload);
      if (opened != null) return opened.original;
    }

    final pool = entry.isVideo ? CachePool.video : CachePool.photo;
    final cached = await _cache.read(pool, keys, entry.objectKey);
    if (cached != null) return cached;

    final object = await _bucket.object(entry.objectKey);
    if (object == null) return null;
    final payload = payloadOf(object);
    if (payload == null) return null;
    final opened = openCarrier(
      cipher: _cipher,
      keys: keys.carrier,
      payload: payload,
    );
    if (opened == null) return null;
    await _cache.write(pool, keys, entry.objectKey, opened.original);
    return opened.original;
  }

  /// Fetches [entry]'s carrier back from the bucket and keeps it, so the
  /// photo is on this phone again. The opposite of [sendBackToBucket].
  Future<bool> download(IndexEntry entry) async {
    final object = await _bucket.object(entry.objectKey);
    if (object == null) return false;
    // Only a carrier this album's key can open: anything else is somebody
    // else's object, or a truncated download, and storing it would leave a
    // photo that claims to be here and opens as nothing.
    final payload = payloadOf(object);
    if (payload == null) return false;
    if (openCarrier(cipher: _cipher, keys: keys.carrier, payload: payload) ==
        null) {
      return false;
    }
    return await _store.putCarrierBytes(keys, entry.objectKey, object) != null;
  }

  /// Drops the full local copy and keeps the tile, for a photo the user is
  /// happy to leave in the bucket. Refuses when the bucket hasn't got it:
  /// this app's copy is the only one until something else can be shown to
  /// hold it, and "free up space" must never mean "lose the photo".
  Future<bool> sendBackToBucket(IndexEntry entry) async {
    if (await _bucket.thumbnailPrefix(entry.objectKey) == null) return false;
    final tile = await thumbnail(entry.objectKey);
    return _store.sendBackToBucket(keys, entry.objectKey, thumbnail: tile);
  }

  Uint8List? _openPrefix(Uint8List prefix) {
    final payload = payloadOfPrefix(prefix);
    if (payload == null) return null;
    return openThumbnail(
      cipher: _cipher,
      keys: keys.carrier,
      payloadPrefix: payload,
    );
  }

  void dispose() => _memory.clear();
}

/// The payload out of a *partial* carrier — a JPEG prefix has its segments,
/// an MP4 one does not, since its boxes are only parseable whole.
Uint8List? payloadOfPrefix(Uint8List prefix) {
  final jpeg = carrierPayloadFromPrefix(prefix);
  if (jpeg.isNotEmpty) return jpeg;
  return payloadOf(prefix);
}

/// One tile. Asks for its own bytes, and says nothing while it waits — a
/// spinner per tile on a scrolling grid is worse than an empty square.
class VaultTile extends StatefulWidget {
  const VaultTile({
    super.key,
    required this.gallery,
    required this.entry,
    this.onTap,
    this.onLongPress,
    this.selecting = false,
    this.selected = false,
    this.onThisPhone = true,
  });

  final VaultGallery gallery;
  final IndexEntry entry;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  final bool selecting;
  final bool selected;

  /// False for a photo whose full copy is in the bucket only. Marked rather
  /// than hidden or dimmed: it is still the user's photo and still opens,
  /// it just costs a download first.
  final bool onThisPhone;

  @override
  State<VaultTile> createState() => _VaultTileState();
}

class _VaultTileState extends State<VaultTile> {
  Uint8List? _bytes;
  var _tried = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await widget.gallery.thumbnail(widget.entry.objectKey);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _tried = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bytes = _bytes;
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: const Color(0xFF1C1C1E),
            child: bytes != null
                ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
                : Center(
                    child: _tried
                        ? Text(
                            l10n.vaultLockedItem,
                            style: const TextStyle(
                              fontSize: 11,
                              color: CupertinoColors.systemGrey,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
          ),
          // Bottom-left, small, and only on the ones that aren't here — the
          // ordinary case earns no badge, so the marked tiles are the answer
          // to "what would I have to wait for".
          if (!widget.onThisPhone)
            const Positioned(
              left: 4,
              bottom: 4,
              child: Icon(
                CupertinoIcons.cloud,
                size: 13,
                color: CupertinoColors.white,
                shadows: [Shadow(blurRadius: 3, color: Color(0x99000000))],
              ),
            ),
          if (widget.selecting)
            Positioned(
              right: 4,
              top: 4,
              child: Icon(
                widget.selected
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                size: 20,
                color: widget.selected
                    ? CupertinoColors.activeBlue
                    : CupertinoColors.white,
                shadows: const [
                  Shadow(blurRadius: 3, color: Color(0x99000000)),
                ],
              ),
            ),
          if (widget.selecting && widget.selected)
            const DecoratedBox(
              decoration: BoxDecoration(color: Color(0x330A84FF)),
              child: SizedBox.expand(),
            ),
        ],
      ),
    );
  }
}
