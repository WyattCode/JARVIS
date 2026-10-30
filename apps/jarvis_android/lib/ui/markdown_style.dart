import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'design_tokens.dart';
import 'motion.dart';

final _letter = RegExp(r'\p{L}', unicode: true);

/// The reading direction of [text], from its first strongly directional letter: Hebrew, Arabic, Syriac and their
/// neighbours run right to left, every other script left to right (Chinese and Latin included). Null while there is no
/// letter yet (digits, punctuation, emoji): the surrounding direction stays.
TextDirection? textDirectionOf(String text) {
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (!_letter.hasMatch(char)) continue;
    final rtl =
        (rune >= 0x0590 && rune <= 0x08ff) ||
        (rune >= 0xfb1d && rune <= 0xfdff) ||
        (rune >= 0xfe70 && rune <= 0xfeff) ||
        (rune >= 0x10800 && rune <= 0x10fff) ||
        (rune >= 0x1e800 && rune <= 0x1efff);
    return rtl ? TextDirection.rtl : TextDirection.ltr;
  }
  return null;
}

String get _monospace =>
    defaultTargetPlatform == TargetPlatform.iOS ? 'Menlo' : 'monospace';

({
  ThemeData theme,
  double fontSize,
  TargetPlatform platform,
  MarkdownStyleSheet sheet,
})?
_styleCache;

/// Chat replies: links in the app's own cyan (not the stock blue), rounded tables with a tinted header row,
/// monospace inline code, and a calmer rhythm between list items.
///
/// Every reply asks for it on every rebuild (streaming rebuilds the page ~30 times a second), so the last result is
/// kept for as long as theme, size and platform stay the same.
MarkdownStyleSheet chatMarkdownStyle(BuildContext context, double fontSize) {
  final theme = Theme.of(context);
  final cached = _styleCache;
  if (cached != null &&
      cached.fontSize == fontSize &&
      cached.platform == defaultTargetPlatform &&
      (identical(cached.theme, theme) || cached.theme == theme)) {
    return cached.sheet;
  }
  final sheet = _buildChatMarkdownStyle(theme, fontSize);
  _styleCache = (
    theme: theme,
    fontSize: fontSize,
    platform: defaultTargetPlatform,
    sheet: sheet,
  );
  return sheet;
}

MarkdownStyleSheet _buildChatMarkdownStyle(ThemeData theme, double fontSize) {
  final colors = theme.colorScheme;
  final base = MarkdownStyleSheet.fromTheme(
    theme.copyWith(
      textTheme: theme.textTheme.apply(
        fontSizeDelta: fontSize - (theme.textTheme.bodyMedium?.fontSize ?? 14),
      ),
    ),
  );
  final dark = theme.brightness == Brightness.dark;
  final link = dark ? const Color(0xffa0d9e5) : const Color(0xff1d6f8a);
  final line = colors.outlineVariant.withValues(alpha: .7);
  // One line height for running text, as in the user's own bubbles.
  const lineHeight = 1.6;
  // A heading after a paragraph or list gets room above it; the first thing in a reply has no use for it.
  const headingTop = EdgeInsets.only(top: 12);
  return base.copyWith(
    p: base.p?.copyWith(height: lineHeight),
    listBullet: base.listBullet?.copyWith(height: lineHeight),
    h1Padding: headingTop,
    h2Padding: headingTop,
    h3Padding: const EdgeInsets.only(top: 10),
    a: TextStyle(
      color: link,
      decoration: TextDecoration.underline,
      decorationColor: link.withValues(alpha: .5),
    ),
    code: TextStyle(
      fontFamily: _monospace,
      fontSize: fontSize * .9,
      backgroundColor: colors.surfaceContainerHigh,
    ),
    blockSpacing: 8,
    listBulletPadding: const EdgeInsets.only(right: 6),
    tableBorder: TableBorder.all(
      color: line,
      borderRadius: BorderRadius.circular(Radii.small),
    ),
    tableHeadAlign: TextAlign.start,
    tableHead: base.tableHead?.copyWith(fontWeight: FontWeight.w600),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    tableHeadCellsPadding: const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 8,
    ),
    tableHeadCellsDecoration: BoxDecoration(color: colors.surfaceContainerHigh),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: line, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 12),
  );
}

(double, Map<String, MarkdownElementBuilder>)? _buildersCache;

/// Fenced code with its language, a copy button that confirms in place, and horizontal scrolling for long lines.
Map<String, MarkdownElementBuilder> chatMarkdownBuilders(double fontSize) {
  final cached = _buildersCache;
  if (cached != null && cached.$1 == fontSize) return cached.$2;
  final builders = <String, MarkdownElementBuilder>{
    'pre': _CodeBlockBuilder(fontSize),
  };
  _buildersCache = (fontSize, builders);
  return builders;
}

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
  bool copied = false;
  Timer? timer;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void copy() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.code)));
    HapticFeedback.selectionClick();
    setState(() => copied = true);
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = colors.onSurfaceVariant;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.small),
        // Increase Contrast: the block gets an edge instead of relying on a faint tint.
        border: MediaQuery.highContrastOf(context)
            ? Border.all(color: colors.outline)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The language and the copy button are the block's chrome: a selection (and so a copy) across the reply must
          // not pick them up.
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.language,
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: copy,
                    style: TextButton.styleFrom(
                      foregroundColor: copied ? colors.primary : muted,
                      minimumSize: const Size(44, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    icon: AnimatedSwitcher(
                      duration: motion(context, 150),
                      transitionBuilder: popTransition,
                      child: Icon(
                        copied ? Icons.check_rounded : Icons.copy_outlined,
                        key: ValueKey(copied),
                        size: 15,
                      ),
                    ),
                    label: Text(copied ? '已复制' : '复制'),
                  ),
                ],
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            // Plain text: the reply's SelectionArea selects it together with the paragraphs around it.
            child: Text(
              widget.code,
              style: TextStyle(
                fontFamily: _monospace,
                fontSize: widget.fontSize,
                height: 1.5,
                color: colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
