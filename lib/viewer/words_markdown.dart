import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'video_controls.dart';

/// The Markdown subset the Mac export writes: headings, paragraphs, quotes,
/// lists, rules, code fences, `**bold**`, `*italic*`, links, and
/// `![](media/…)` pictures and videos. Forty lines of parsing rather than a
/// Markdown package (see `CLAUDE.md`).
sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text, {this.quote = false, this.bullet});
  final String text;
  final bool quote;

  /// "•" or "3." for a list item.
  final String? bullet;
}

class MdCode extends MdBlock {
  const MdCode(this.text);
  final String text;
}

class MdRule extends MdBlock {
  const MdRule();
}

class MdMedia extends MdBlock {
  const MdMedia(this.path, this.alt);
  final String path;
  final String alt;

  bool get isVideo => const {
    '.mp4',
    '.mov',
    '.m4v',
    '.3gp',
  }.contains(p.extension(path).toLowerCase());
}

final _media = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _bullet = RegExp(r'^\s*(?:[-*+]|(\d+)[.)])\s+(.*)$');

List<MdBlock> parseMarkdown(String text) {
  final blocks = <MdBlock>[];
  final para = <String>[];
  var quote = false;

  void flush() {
    if (para.isNotEmpty) {
      blocks.add(MdParagraph(para.join('\n'), quote: quote));
      para.clear();
    }
    quote = false;
  }

  final lines = text.replaceAll('\r\n', '\n').split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      flush();
      final code = <String>[];
      while (++i < lines.length && !lines[i].trim().startsWith('```')) {
        code.add(lines[i]);
      }
      blocks.add(MdCode(code.join('\n')));
      continue;
    }
    if (trimmed.isEmpty) {
      flush();
      continue;
    }
    if (RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
      flush();
      blocks.add(const MdRule());
      continue;
    }
    if (_heading.firstMatch(trimmed) case final m?) {
      flush();
      blocks.add(MdHeading(m[1]!.length, m[2]!.trim()));
      continue;
    }
    // A picture anywhere in a line breaks it: text before, the picture,
    // text after.
    if (_media.hasMatch(line)) {
      var cursor = 0;
      for (final m in _media.allMatches(line)) {
        final before = line.substring(cursor, m.start).trim();
        if (before.isNotEmpty) para.add(before);
        flush();
        blocks.add(MdMedia(m[2]!, m[1]!));
        cursor = m.end;
      }
      final tail = line.substring(cursor).trim();
      if (tail.isNotEmpty) para.add(tail);
      continue;
    }
    if (_bullet.firstMatch(line) case final m?) {
      flush();
      blocks.add(MdParagraph(m[2]!, bullet: m[1] == null ? '•' : '${m[1]}.'));
      continue;
    }
    if (trimmed.startsWith('>')) {
      if (!quote) flush();
      quote = true;
      para.add(trimmed.replaceFirst(RegExp(r'^>\s?'), ''));
      continue;
    }
    if (quote) flush();
    para.add(line);
  }
  flush();
  return blocks;
}

final _inline = RegExp(
  r'\*\*(.+?)\*\*|(?<![*\w])\*(?!\s)(.+?)\*|\[([^\]]+)\]\(([^)\s]+)\)',
);

/// `**bold**`, `*italic*` and `[text](url)` as spans; [recognizers] keeps
/// the link taps for the caller to dispose.
List<InlineSpan> inlineSpans(
  String text,
  TextStyle base,
  List<TapGestureRecognizer> recognizers,
) {
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, m.start)));
    }
    if (m[1] != null) {
      spans.add(
        TextSpan(
          text: m[1],
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
    } else if (m[2] != null) {
      spans.add(
        TextSpan(
          text: m[2],
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    } else {
      final url = Uri.tryParse(m[4]!);
      final tap = TapGestureRecognizer()
        ..onTap = () {
          if (url != null) launchUrl(url, mode: LaunchMode.externalApplication);
        };
      recognizers.add(tap);
      spans.add(
        TextSpan(
          text: m[3],
          style: const TextStyle(
            color: CupertinoColors.activeBlue,
            decoration: TextDecoration.underline,
          ),
          recognizer: tap,
        ),
      );
    }
    cursor = m.end;
  }
  if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
  return spans;
}

/// A picture of a writing, decoded at the width it is shown, never larger.
class WordsImage extends StatelessWidget {
  const WordsImage({super.key, required this.file, required this.alt});

  final File file;
  final String alt;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        CupertinoPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => _FullImage(file: file),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          file,
          cacheWidth: (width * dpr).round(),
          fit: BoxFit.fitWidth,
          errorBuilder: (_, _, _) => _Missing(label: alt),
        ),
      ),
    );
  }
}

class _FullImage extends StatelessWidget {
  const _FullImage({required this.file});
  final File file;

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    backgroundColor: CupertinoColors.black,
    navigationBar: const CupertinoNavigationBar(),
    child: InteractiveViewer(
      maxScale: 5,
      child: Center(child: Image.file(file)),
    ),
  );
}

/// A video of a writing: a tile until tapped, then a player page.
class WordsVideo extends StatelessWidget {
  const WordsVideo({super.key, required this.file, required this.alt});

  final File file;
  final String alt;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => Navigator.of(context).push(
      CupertinoPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _VideoPage(file: file),
      ),
    ),
    child: Container(
      height: 180,
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            CupertinoIcons.play_circle_fill,
            size: 48,
            color: CupertinoColors.white,
          ),
          if (alt.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              alt,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
          ],
        ],
      ),
    ),
  );
}

class _VideoPage extends StatefulWidget {
  const _VideoPage({required this.file});
  final File file;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  late final _controller = VideoPlayerController.file(widget.file);
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      _controller.play();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    backgroundColor: CupertinoColors.black,
    navigationBar: const CupertinoNavigationBar(),
    child: SafeArea(
      child: !_ready
          ? const Center(child: CupertinoActivityIndicator())
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    ),
                  ),
                ),
                VideoControls(controller: _controller),
              ],
            ),
    ),
  );
}

class _Missing extends StatelessWidget {
  const _Missing({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    height: 80,
    color: const Color(0xFF2C2C2E),
    alignment: Alignment.center,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(CupertinoIcons.photo, color: CupertinoColors.systemGrey),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(color: CupertinoColors.systemGrey),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    ),
  );
}
