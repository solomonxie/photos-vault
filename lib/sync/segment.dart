import 'dart:convert';
import 'dart:io' show gzip;

import 'op.dart';

const protocolVersion = 1;
const segmentMaxOps = 200;

/// One immutable file of one device's ops: `sync/log/<d>/<seq:012d>.ndjson.gz`.
class Segment {
  Segment({
    required this.d,
    required this.seq,
    required this.vv,
    required this.ops,
    this.lastModified = 0,
  });

  final String d;
  final int seq;
  final Map<String, int> vv;
  final List<Op> ops;

  /// Server time the object landed; 0 until read back from the bucket.
  final int lastModified;

  static String key(String d, int seq) =>
      'sync/log/$d/${seq.toString().padLeft(12, '0')}.ndjson.gz';

  /// Seq from a key made by [key]; null for anything else.
  static int? seqOf(String key) {
    final m = RegExp(r'/(\d{12})\.ndjson\.gz$').firstMatch(key);
    return m == null ? null : int.parse(m.group(1)!);
  }

  List<int> encode() => gzip.encode(
    utf8.encode(
      [
        jsonEncode({
          'v': protocolVersion,
          'd': d,
          'seq': seq,
          'vv': vv,
          'n': ops.length,
        }),
        for (final op in ops) jsonEncode(op.toJson()),
      ].join('\n'),
    ),
  );

  /// Throws [FormatException] on a truncated or newer-protocol segment.
  static Segment decode(List<int> bytes, {required int lastModified}) {
    final lines = const LineSplitter()
        .convert(utf8.decode(gzip.decode(bytes)))
        .where((l) => l.isNotEmpty)
        .toList();
    final head = jsonDecode(lines.first) as Map<String, Object?>;
    final v = head['v'] as int;
    if (v > protocolVersion) throw NewerProtocol(v);
    final d = head['d'] as String;
    final seq = head['seq'] as int;
    final vv = (head['vv'] as Map).cast<String, int>();
    final ops = [
      for (final l in lines.skip(1))
        Op.fromJson(
          jsonDecode(l) as Map<String, Object?>,
          d: d,
          seq: seq,
          vv: vv,
        ),
    ];
    if (ops.length != head['n']) {
      throw FormatException(
        'segment $d/$seq: ${ops.length} of ${head['n']} ops',
      );
    }
    return Segment(
      d: d,
      seq: seq,
      vv: vv,
      ops: ops,
      lastModified: lastModified,
    );
  }
}

/// A segment written by a newer app: stop writing, keep reading what we can.
class NewerProtocol extends FormatException {
  NewerProtocol(int v)
    : super('sync protocol $v is newer than $protocolVersion');
}
