import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'markdown_style.dart';

final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})');
final _listMarker = RegExp(r'^(?:[-*+]|\d{1,9}[.)])(?:\s|$)');
final _linkDefinition = RegExp(r'^ {0,3}\[[^\]]+\]:', multiLine: true);

/// A line that continues the block before it: indented, a quote or a table row.
final _continues = RegExp(r'^[ \t>|]');
final _underline = RegExp(r'^(?:=+|-+)\s*$');

/// Cuts a Markdown reply into top-level blocks that render the same on their own as inside the whole text, so the
/// ones that are finished need not be parsed and built again while the last one is still growing.
///
/// A cut is made only before a line that starts at column 0 after a blank line, outside a fenced code block, and
/// that is not the start of a list item, a quote, a table row, an indented line or a heading underline: those can
/// continue the block before them. Text with link reference definitions is never cut (a definition at the end can
/// belong to a link at the start).
List<String> splitReply(String text) {
  if (text.length < 400 || _linkDefinition.hasMatch(text)) return [text];
  final lines = text.split('\n');
  final blocks = <String>[];
  var start = 0, offset = 0, blockStart = 0;
  String? fenceMark;
  var blankBefore = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (i > blockStart &&
        blankBefore &&
        fenceMark == null &&
        line.isNotEmpty &&
        !_continues.hasMatch(line) &&
        !_listMarker.hasMatch(line) &&
        !_underline.hasMatch(line)) {
      blocks.add(text.substring(start, offset).trimRight());
      start = offset;
      blockStart = i;
    }
    final match = _fence.firstMatch(line);
    if (fenceMark != null) {
      final mark = match?.group(1);
      if (mark != null &&
          mark[0] == fenceMark[0] &&
          mark.length >= fenceMark.length &&
          line.trim() == mark) {
        fenceMark = null;
      }
    } else if (match != null) {
      fenceMark = match.group(1);
    }
    blankBefore = line.trim().isEmpty;
    offset += line.length + 1;
  }
  blocks.add(text.substring(start));
  return blocks;
}

/// A reply's Markdown as a column of blocks. The widgets of the blocks that are finished are kept and handed back
/// unchanged, so Flutter skips them: while a reply streams in, only its last block is parsed and built each time.
/// The result looks as the whole text in one [MarkdownBody] does (the gap between blocks is the style's).
class ReplyMarkdown extends StatefulWidget {
  const ReplyMarkdown({
    super.key,
    required this.text,
    required this.fontSize,
    required this.onTapLink,
    required this.imageBuilder,
  });
  final String text;
  final double fontSize;
  final MarkdownTapLinkCallback onTapLink;
  final MarkdownImageBuilder imageBuilder;

  @override
  State<ReplyMarkdown> createState() => _ReplyMarkdownState();
}

class _ReplyMarkdownState extends State<ReplyMarkdown> {
  /// The widgets built for the blocks of the last build, by block text; valid for [_sheet] and [_fontSize].
  final _built = <String, Widget>{};
  MarkdownStyleSheet? _sheet;
  double? _fontSize;
  Map<String, MarkdownElementBuilder>? _builders;

  Widget _block(String text, MarkdownStyleSheet sheet) => MarkdownBody(
    key: ValueKey(text.hashCode),
    styleSheet: sheet,
    builders: _builders!,
    data: text,
    onTapLink: widget.onTapLink,
    imageBuilder: widget.imageBuilder,
  );

  @override
  Widget build(BuildContext context) {
    final sheet = chatMarkdownStyle(context, widget.fontSize);
    if (!identical(sheet, _sheet) || widget.fontSize != _fontSize) {
      _built.clear();
      _sheet = sheet;
      _fontSize = widget.fontSize;
      _builders = chatMarkdownBuilders(widget.fontSize);
    }
    final blocks = splitReply(widget.text);
    if (blocks.length == 1) return _block(blocks.single, sheet);
    final used = <String, Widget>{};
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final text = blocks[i];
      // Only a finished block is kept: the last one changes with every chunk.
      final kept = i < blocks.length - 1 ? _built[text] : null;
      final widget = kept ?? _block(text, sheet);
      if (i < blocks.length - 1) used[text] = widget;
      if (i > 0) children.add(SizedBox(height: sheet.blockSpacing));
      children.add(widget);
    }
    _built
      ..clear()
      ..addAll(used);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
