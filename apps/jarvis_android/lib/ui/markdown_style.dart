import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'markdown_palette.dart';
import 'motion.dart';

String get _monospace =>
    defaultTargetPlatform == TargetPlatform.iOS ? 'Menlo' : 'monospace';

/// A table column as wide as its widest cell (the cell's own padding counts), but never narrower than [min] nor wider
/// than [max]: a long cell wraps inside the widest column, a short one keeps a column that is easy to read. Being an
/// [IntrinsicColumnWidth], it also makes the Markdown package put the table in a sideways scroll view.
class ClampedIntrinsicColumnWidth extends IntrinsicColumnWidth {
  const ClampedIntrinsicColumnWidth({this.min = 64, this.max = 280});
  final double min, max;

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      super.minIntrinsicWidth(cells, containerWidth).clamp(min, max);

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      super.maxIntrinsicWidth(cells, containerWidth).clamp(min, max);
}

/// Chat replies as the iOS app sets them (NativeMarkdown.swift): a line height of 1.6, headings a step larger and
/// semibold, links in the app's cyan with a full-colour underline, quotes and list markers in the quiet text colour,
/// a 1 pt hairline for rules and table lines, and rounded tables with a tinted header row.
MarkdownStyleSheet chatMarkdownStyle(BuildContext context, double fontSize) {
  final theme = Theme.of(context);
  final base = MarkdownStyleSheet.fromTheme(
    theme.copyWith(
      textTheme: theme.textTheme.apply(
        fontSizeDelta: fontSize - (theme.textTheme.bodyMedium?.fontSize ?? 14),
      ),
    ),
  );
  final palette = ChatPalette.of(context);
  final link = palette.accent, line = palette.outlineVariant;
  final muted = palette.onSurfaceVariant;
  final body = (base.p ?? const TextStyle()).copyWith(
    fontSize: fontSize,
    height: 1.6,
  );
  // A heading's line box is 1.25 of its font's own line, but never less than a body line (iOS: max(body, 1.25 x font)).
  TextStyle heading(double factor, double height) => body.copyWith(
    fontSize: fontSize * factor,
    fontWeight: FontWeight.w600,
    height: height,
  );
  final cell = body.copyWith(fontSize: fontSize * .95, height: 1.2);
  return base.copyWith(
    p: body,
    a: TextStyle(
      color: link,
      decoration: TextDecoration.underline,
      decorationColor: link,
    ),
    code: TextStyle(
      fontFamily: _monospace,
      fontSize: fontSize * .9,
      backgroundColor: palette.containerHigh,
    ),
    h1: heading(1.5, 1.5),
    h2: heading(1.3, 1.5),
    h3: heading(1.15, 1.5),
    h4: heading(1, 1.6),
    h5: heading(1, 1.6),
    h6: heading(1, 1.6),
    // Space above a heading (12 for the two largest, 10 for the rest) on top of the 8 between blocks, which is also the
    // 8 below it.
    h1Padding: const EdgeInsets.only(top: 12),
    h2Padding: const EdgeInsets.only(top: 12),
    h3Padding: const EdgeInsets.only(top: 10),
    h4Padding: const EdgeInsets.only(top: 10),
    h5Padding: const EdgeInsets.only(top: 10),
    h6Padding: const EdgeInsets.only(top: 10),
    blockSpacing: 8,
    listBullet: body.copyWith(color: muted),
    listIndent: 20,
    listBulletPadding: const EdgeInsets.only(right: 6),
    blockquote: body.copyWith(color: muted),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: line, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 14),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: line, width: 1)),
    ),
    tableBorder: TableBorder(
      top: BorderSide(color: line),
      right: BorderSide(color: line),
      bottom: BorderSide(color: line),
      left: BorderSide(color: line),
      horizontalInside: BorderSide(color: line),
      borderRadius: BorderRadius.circular(10),
    ),
    tableColumnWidth: const ClampedIntrinsicColumnWidth(),
    tablePadding: EdgeInsets.zero,
    tableHeadAlign: TextAlign.start,
    tableHead: cell.copyWith(fontWeight: FontWeight.w600),
    tableBody: cell,
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    tableHeadCellsPadding: const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 8,
    ),
    tableHeadCellsDecoration: BoxDecoration(
      color: palette.containerHigh,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
    ),
  );
}

/// Fenced code with its language, a copy button that confirms in place, and horizontal scrolling for long lines.
Map<String, MarkdownElementBuilder> chatMarkdownBuilders(double fontSize) => {
  'pre': _CodeBlockBuilder(fontSize),
};

class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.fontSize);

  /// The chat text size; a top-level block has no parent style to take it from.
  final double fontSize;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final child = element.children?.firstOrNull;
    final language = child is md.Element
        ? (child.attributes['class'] ?? '').replaceFirst('language-', '')
        : '';
    return CodeBlock(
      code: element.textContent.replaceFirst(RegExp(r'\n+$'), ''),
      language: language,
      fontSize: fontSize * .9,
    );
  }
}

class CodeBlock extends StatefulWidget {
  const CodeBlock({
    super.key,
    required this.code,
    this.language = '',
    this.fontSize = 14,
  });
  final String code, language;
  final double fontSize;
  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool copied = false, copying = false, copyFailed = false;
  int copyEpoch = 0;
  Timer? timer;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code) {
      copyEpoch++;
      timer?.cancel();
      copied = copying = copyFailed = false;
    }
  }

  Future<void> copy() async {
    if (copying) return;
    final epoch = ++copyEpoch;
    timer?.cancel();
    setState(() {
      copying = true;
      copied = copyFailed = false;
    });
    var success = false;
    try {
      await Clipboard.setData(ClipboardData(text: widget.code));
      success = true;
    } catch (_) {
      // The clipboard can be unavailable; never claim an unsuccessful write succeeded.
    }
    if (!mounted || epoch != copyEpoch) return;
    setState(() {
      copying = false;
      copied = success;
      copyFailed = !success;
    });
    if (success) HapticFeedback.selectionClick();
    timer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted && epoch == copyEpoch) {
        setState(() {
          copied = copyFailed = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = ChatPalette.of(context);
    final muted = palette.onSurfaceVariant;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.containerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A 36 high header, 2 below the top: the language at 14, the copy button 2 from the right edge.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 2, 0),
            child: SizedBox(
              height: 36,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.language,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: copying ? null : copy,
                    style: TextButton.styleFrom(
                      foregroundColor: copyFailed
                          ? colors.error
                          : copied
                          ? palette.accent
                          : muted,
                      minimumSize: const Size(44, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSwitcher(
                          duration: motion(context, 150),
                          transitionBuilder: popTransition,
                          child: Icon(
                            copyFailed
                                ? Icons.error_outline
                                : copied
                                ? Icons.check_rounded
                                : Icons.copy_outlined,
                            key: ValueKey((copied, copyFailed)),
                            size: 13,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          copying
                              ? '复制中'
                              : copyFailed
                              ? '复制失败'
                              : copied
                              ? '已复制'
                              : '复制',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: SelectableText(
              widget.code,
              style: TextStyle(
                fontFamily: _monospace,
                fontSize: widget.fontSize,
                height: 1.25,
                color: colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
