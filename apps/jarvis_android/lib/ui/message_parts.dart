import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The thinking of a reply, folded: a 48 dp row with the title and a chevron,
/// and under it, when opened, the words with a thin bar at their left. (As on
/// iOS: the words are quieter than the reply's own.)
class ReasoningBlock extends StatefulWidget {
  const ReasoningBlock({
    super.key,
    required this.text,
    required this.size,
    required this.thinking,
    this.onOpened,
  });
  final String text;

  /// The reply's own text size; the thinking is a little smaller.
  final double size;

  /// The reply has no words yet: still thinking.
  final bool thinking;
  final VoidCallback? onOpened;

  @override
  State<ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<ReasoningBlock> {
  bool open = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The block stays as it was left through a rebuild of the list.
    final saved = PageStorage.maybeOf(context)
        ?.readState(context, identifier: 'reasoning-open');
    if (saved is bool) open = saved;
  }

  void toggle() {
    setState(() => open = !open);
    PageStorage.maybeOf(context)
        ?.writeState(context, open, identifier: 'reasoning-open');
    if (open) widget.onOpened?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: open,
          label: widget.thinking ? '思考中' : '思考过程',
          hint: open ? '已展开，点按收起' : '已收起，点按展开',
          excludeSemantics: true,
          onTap: toggle,
          child: InkWell(
            key: const Key('reasoning-toggle'),
            onTap: toggle,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  Text(
                    widget.thinking ? '思考中…' : '思考过程',
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            // A thin bar at the left, 14 in from the words.
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: colors.outlineVariant, width: 2),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: SizedBox(
                  width: double.infinity,
                  child: SelectableText(
                    key: const PageStorageKey<String>('reasoning-text'),
                    widget.text,
                    style: TextStyle(
                      fontSize: widget.size - 1.5,
                      height: 1.6,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A line of quiet status with a small spinner: "正在思考…", "正在调用工具…".
class MessageStatusRow extends StatelessWidget {
  const MessageStatusRow(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// The copy button of a reply: the glyph turns to a check for a moment, with a
/// light tick, so that the copy is known to have happened.
class CopyReplyButton extends StatefulWidget {
  const CopyReplyButton({super.key, required this.text});
  final String text;

  @override
  State<CopyReplyButton> createState() => _CopyReplyButtonState();
}

class _CopyReplyButtonState extends State<CopyReplyButton> {
  bool copied = false;
  int serial = 0;

  Future<void> copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    HapticFeedback.selectionClick().catchError((Object _) {});
    final mine = ++serial;
    setState(() => copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted && mine == serial) setState(() => copied = false);
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: copied ? '已复制' : '复制回复',
    onPressed: copy,
    alignment: Alignment.centerLeft,
    padding: EdgeInsets.zero,
    style: IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      fixedSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const CircleBorder(),
    ),
    icon: Icon(
      copied ? Icons.check : Icons.copy_outlined,
      size: 15,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
