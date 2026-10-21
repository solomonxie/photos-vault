import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

/// `http(s)://…` or `www.…`, up to whitespace; trailing punctuation that
/// usually ends a sentence rather than a link is left out.
final _link = RegExp(r'''(?:https?://|www\.)[^\s<>"']+[^\s<>"'.,;:!?)\]]''');

/// [text] with its links tappable, opening in the system browser. A tap
/// anywhere else falls through to whatever is underneath.
class LinkText extends StatefulWidget {
  const LinkText(this.text, {super.key, this.style, this.maxLines});

  final String text;
  final TextStyle? style;
  final int? maxLines;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final spans = <TextSpan>[];
    var at = 0;
    for (final match in _link.allMatches(widget.text)) {
      if (match.start > at) {
        spans.add(TextSpan(text: widget.text.substring(at, match.start)));
      }
      final link = match.group(0)!;
      final recognizer = TapGestureRecognizer()..onTap = () => openLink(link);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: link,
          recognizer: recognizer,
          style: const TextStyle(
            color: CupertinoColors.activeBlue,
            decoration: TextDecoration.underline,
            decorationColor: CupertinoColors.activeBlue,
          ),
        ),
      );
      at = match.end;
    }
    if (at < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(at)));
    }
    return Text.rich(
      TextSpan(style: widget.style, children: spans),
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

/// The links in [text], in order.
List<String> linksIn(String text) => [
  for (final m in _link.allMatches(text)) m.group(0)!,
];

/// In the system browser; `www.` gets `https://`.
void openLink(String link) {
  final uri = Uri.tryParse(link.startsWith('www.') ? 'https://$link' : link);
  if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Each link in [text] as its own tappable line — under a field that
/// can't be tapped through, like an editable caption.
class LinkList extends StatelessWidget {
  const LinkList(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final links = linksIn(text);
    if (links.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final link in links)
          CupertinoButton(
            padding: const EdgeInsets.symmetric(vertical: 4),
            minimumSize: Size.zero,
            alignment: Alignment.centerLeft,
            onPressed: () => openLink(link),
            child: Row(
              children: [
                const Icon(CupertinoIcons.link, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    link,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      color: CupertinoColors.activeBlue,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
