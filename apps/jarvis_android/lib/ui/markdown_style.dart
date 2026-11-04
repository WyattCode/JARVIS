import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'motion.dart';

String get _monospace =>
    defaultTargetPlatform == TargetPlatform.iOS ? 'Menlo' : 'monospace';

/// Chat replies: links in the app's own cyan (not the stock blue), rounded tables with a tinted header row,
/// monospace inline code, and a calmer rhythm between list items.
MarkdownStyleSheet chatMarkdownStyle(BuildContext context, double fontSize) {
  final theme = Theme.of(context), colors = theme.colorScheme;
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
  return base.copyWith(
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
      borderRadius: BorderRadius.circular(12),
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
    final muted = colors.onSurfaceVariant;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
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
                  onPressed: copying ? null : copy,
                  style: TextButton.styleFrom(
                    foregroundColor: copyFailed
                        ? colors.error
                        : copied
                        ? colors.primary
                        : muted,
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  icon: AnimatedSwitcher(
                    duration: motion(context, 150),
                    transitionBuilder: popTransition,
                    child: Icon(
                      copyFailed
                          ? Icons.error_outline
                          : copied
                          ? Icons.check_rounded
                          : Icons.copy_outlined,
                      key: ValueKey((copied, copyFailed)),
                      size: 15,
                    ),
                  ),
                  label: Text(
                    copying
                        ? '复制中'
                        : copyFailed
                        ? '复制失败'
                        : copied
                        ? '已复制'
                        : '复制',
                  ),
                ),
              ],
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
