import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../model/conversation_rows.dart';
import '../model/fold_proportions.dart';
import '../state/jarvis_controller.dart';
import 'login_art.dart' show JarvisMark;

/// How the list stands: as a drawer over the chat, docked beside it, or as a
/// page of its own that covers the window.
enum SidebarMode { drawer, docked, page }

/// The conversation-list mark of the bar: two long lines and a short one.
class ListGlyph extends StatelessWidget {
  const ListGlyph({super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(20, 21),
    painter: _ListGlyphPainter(Theme.of(context).colorScheme.onSurface),
  );
}

class _ListGlyphPainter extends CustomPainter {
  _ListGlyphPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final (y, width) in [(3.0, 19.0), (10.5, 19.0), (18.0, 9.5)]) {
      canvas.drawLine(Offset(1, y), Offset(width - 1, y), paint);
    }
  }

  @override
  bool shouldRepaint(_ListGlyphPainter old) => old.color != color;
}

/// The conversation list, as the iOS app has it: the brand row; a bar of round
/// buttons where the list is docked or a page of its own; a heading ("最近", or
/// the day sections); a search field from six conversations on (or when the
/// bar's search button asks for it); soft rows 58 high, held for their menu.
/// There is no wide "new conversation" button and no settings row here: those
/// live in the chat's own bar.
class ConversationSidebar extends StatefulWidget {
  const ConversationSidebar({
    super.key,
    required this.controller,
    required this.mode,
    required this.onChoose,
    required this.onNew,
    required this.onSettings,
    required this.onRename,
    required this.onDelete,
    this.onClose,
    this.rightGap = 0,
    this.notice,
  });
  final JarvisController controller;
  final SidebarMode mode;

  /// A conversation was chosen (a drawer closes).
  final VoidCallback onChoose;
  final VoidCallback onNew, onSettings;
  final void Function(String id, String title) onRename;
  final void Function(String id) onDelete;

  /// The list's own close button (the bar's left button).
  final VoidCallback? onClose;

  /// The room beside the crease is kept clear of the rows.
  final double rightGap;
  final Widget? notice;

  @override
  State<ConversationSidebar> createState() => _ConversationSidebarState();
}

class _ConversationSidebarState extends State<ConversationSidebar> {
  final field = TextEditingController();
  final focus = FocusNode();
  bool searchOpen = false;

  @override
  void dispose() {
    field.dispose();
    focus.dispose();
    super.dispose();
  }

  void toggleSearch() {
    setState(() {
      if (searchOpen) {
        searchOpen = false;
        field.clear();
        focus.unfocus();
      } else {
        searchOpen = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) focus.requestFocus();
        });
      }
    });
  }

  Widget barButton(
    Widget icon,
    String tooltip,
    VoidCallback onPressed, {
    Key? key,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      fixedSize: const Size(44, 44),
      foregroundColor: Theme.of(context).colorScheme.onSurface,
    ),
    icon: icon,
  );

  /// The bar of round buttons: close at the left; at the right the settings
  /// (only where the list is a page of its own), new, and search.
  Widget bar() => SizedBox(
    height: 56,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          if (widget.onClose != null)
            barButton(
              const ListGlyph(),
              '收起会话列表',
              widget.onClose!,
              key: const Key('close-conversation-page'),
            ),
          const Spacer(),
          if (widget.mode == SidebarMode.page)
            barButton(
              const Icon(Icons.settings_outlined, size: 21),
              '设置',
              widget.onSettings,
              key: const Key('sidebar-settings'),
            ),
          barButton(
            const Icon(Icons.edit_square, size: 21),
            '新建会话',
            widget.onNew,
            key: const Key('new-conversation'),
          ),
          barButton(
            const Icon(Icons.search, size: 22),
            '搜索会话',
            toggleSearch,
            key: const Key('sidebar-search-button'),
          ),
        ],
      ),
    ),
  );

  Widget brand() {
    final foldable = FoldProportions.isFold(
      MediaQuery.sizeOf(context).width,
      MediaQuery.sizeOf(context).height,
    );
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        key: const ValueKey('sidebar-brand-row'),
        children: [
          const ClipRRect(
            borderRadius: BorderRadius.all(Radius.circular(9)),
            child: JarvisMark(size: 32, tile: true),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'JARVIS',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 18 on a foldable, 20 on a straight phone.
              style: TextStyle(
                fontSize: foldable ? 18 : 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget searchField() {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(23),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: colors.onSurface.withValues(
                alpha: colors.brightness == Brightness.dark ? .12 : .07,
              ),
              borderRadius: BorderRadius.circular(23),
            ),
            child: Row(
              children: [
                Icon(Icons.search, size: 20, color: colors.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('sidebar-search'),
                    controller: field,
                    focusNode: focus,
                    textInputAction: TextInputAction.search,
                    autocorrect: false,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => focus.unfocus(),
                    decoration: const InputDecoration(
                      hintText: '搜索会话',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                if (field.text.isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(field.clear),
                    child: Semantics(
                      button: true,
                      label: '清除搜索',
                      child: Icon(
                        Icons.cancel,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final showSearch =
        searchOpen || c.conversations.length >= ConversationRows.searchFrom;
    final result = ConversationRows.rows(
      c.conversations,
      query: showSearch ? field.text : '',
      selected: c.selectedId,
      generating: c.isGenerating,
    );
    final headed = result.rows.any((r) => r.isHeader);
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(right: widget.rightGap),
        child: Column(
          children: [
            if (widget.mode != SidebarMode.drawer) bar(),
            brand(),
            // The day sections are the list's headings when there are any.
            if (!headed)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Semantics(
                    header: true,
                    child: Text(
                      '最近',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            if (showSearch) searchField(),
            Expanded(
              child: result.found == 0 && c.conversations.isNotEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的会话',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      key: const Key('conversation-list'),
                      itemCount: result.rows.length,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemBuilder: (context, i) {
                        final row = result.rows[i];
                        if (row.isHeader) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(8, 12, 0, 2),
                            child: Semantics(
                              header: true,
                              child: Text(
                                row.title,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          );
                        }
                        return ConversationRowTile(
                          key: ValueKey('conversation-row-${row.id}'),
                          row: row,
                          onTap: () {
                            c.select(row.id);
                            widget.onChoose();
                          },
                          onRename: () => widget.onRename(row.id, row.title),
                          onDelete: () => confirmDelete(row),
                        );
                      },
                    ),
            ),
            ?widget.notice,
          ],
        ),
      ),
    );
  }

  Future<void> confirmDelete(SidebarRow row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('“${row.title}”\n会从这台设备上删除，此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('confirm-delete'),
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDelete(row.id);
  }
}

/// A row of the list: a soft card 58 high, the title at 14 (heavier when it is
/// the one that is open), one colour for all the rows, a step brighter under
/// the finger and with a fine edge in the accent when open. Held for 0.45 s it
/// offers rename and delete.
class ConversationRowTile extends StatefulWidget {
  const ConversationRowTile({
    super.key,
    required this.row,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });
  final SidebarRow row;
  final VoidCallback onTap, onRename, onDelete;

  @override
  State<ConversationRowTile> createState() => _ConversationRowTileState();
}

class _ConversationRowTileState extends State<ConversationRowTile> {
  bool pressed = false;

  Future<void> menu() async {
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    HapticFeedback.mediumImpact().catchError((Object _) {});
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final colors = Theme.of(context).colorScheme;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_outlined),
            title: Text('重命名'),
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.delete_outline, color: colors.error),
            title: Text('删除', style: TextStyle(color: colors.error)),
          ),
        ),
      ],
    );
    if (choice == 'rename') widget.onRename();
    if (choice == 'delete') widget.onDelete();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final still = MediaQuery.disableAnimationsOf(context);
    final selected = widget.row.selected;
    final accent = dark ? const Color(0xff8fdceb) : const Color(0xff137589);
    final fill = pressed
        ? (dark ? const Color(0xff242429) : const Color(0xffe8edeb))
        : (dark ? const Color(0xff1c1c20) : const Color(0xffedf0ef)).withValues(
            alpha: .55,
          );
    return Semantics(
      selected: selected,
      customSemanticsActions: {
        const CustomSemanticsAction(label: '更多操作（重命名、删除）'): menu,
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: AnimatedScale(
          scale: pressed ? .96 : 1,
          duration: Duration(milliseconds: still ? 0 : 300),
          curve: Curves.easeOutBack,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => pressed = true),
            onTapUp: (_) => setState(() => pressed = false),
            onTapCancel: () => setState(() => pressed = false),
            onTap: widget.onTap,
            onLongPressStart: (_) => setState(() => pressed = true),
            onLongPressEnd: (_) => setState(() => pressed = false),
            onLongPress: menu,
            child: AnimatedContainer(
              key: ValueKey('conversation-surface-${widget.row.id}'),
              height: 58,
              duration: Duration(milliseconds: still ? 0 : 150),
              padding: const EdgeInsets.only(left: 12, right: 10),
              decoration: BoxDecoration(
                color: selected
                    ? Color.alphaBlend(
                        colors.onSurface.withValues(alpha: .06),
                        fill,
                      )
                    : fill,
                borderRadius: BorderRadius.circular(16),
                border: selected
                    ? Border.all(color: accent.withValues(alpha: .45))
                    : null,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.row.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                  if (widget.row.generating)
                    const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
