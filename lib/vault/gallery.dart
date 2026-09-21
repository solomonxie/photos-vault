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

/// Draws hidden photos, which are not on this phone.
///
/// Every tile is an object in a bucket, so this cannot meet the scrolling
/// bar the rest of the app holds itself to (CLAUDE.md: a dropped frame is a
/// bug). What makes it tolerable: the thumbnail rides in the first 64 KB of
/// its carrier, so a tile is one ranged GET rather than a 2 MB download;
/// decoded tiles stay in RAM for the session; and the bytes are also kept
/// in an encrypted disk cache, so coming back tomorrow is free.
class VaultGallery {
  VaultGallery({
    required this.keys,
    VaultBucket? bucket,
    VaultCache? cache,
    VaultCipher? cipher,
  }) : _bucket = bucket ?? VaultBucket(),
       _cache = cache ?? VaultCache(),
       _cipher = cipher ?? PlatformCipher();

  final AlbumKeys keys;
  final VaultBucket _bucket;
  final VaultCache _cache;
  final VaultCipher _cipher;

  /// Decoded tiles for this session. Dropped when the album closes, along
  /// with everything else this screen knows.
  final Map<String, Uint8List> _memory = {};

  Future<List<IndexEntry>> list() async =>
      (await _bucket.readAlbum(keys)).entries;

  Future<Uint8List?> thumbnail(String objectKey) async {
    final held = _memory[objectKey];
    if (held != null) return held;

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

  /// The photo itself, from the disk cache when it is there — a video is
  /// minutes and somebody's data plan to fetch twice.
  Future<Uint8List?> original(IndexEntry entry) async {
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
  });

  final VaultGallery gallery;
  final IndexEntry entry;
  final VoidCallback? onTap;

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
      child: Container(
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
    );
  }
}
