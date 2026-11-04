import 'package:flutter/material.dart';

class JarvisMenuAction {
  const JarvisMenuAction(
    this.value,
    this.label, {
    this.icon,
    this.destructive = false,
  });
  final String value, label;
  final IconData? icon;
  final bool destructive;
}

/// Shared action surface, with native Back dismissing the menu before its page.
class JarvisActionMenu extends StatefulWidget {
  const JarvisActionMenu({
    super.key,
    required this.tooltip,
    required this.actions,
    required this.onSelected,
    this.child,
    this.selectedValue,
    this.iconSize = 20,
  });
  final String tooltip;
  final List<JarvisMenuAction> actions;
  final ValueChanged<String> onSelected;
  final Widget? child;
  final String? selectedValue;
  final double iconSize;
  static MenuController? _open;
  static bool get isOpen => _open?.isOpen == true;
  static bool closeOpen() {
    if (_open?.isOpen != true) return false;
    _open!.close();
    return true;
  }

  @override
  State<JarvisActionMenu> createState() => _JarvisActionMenuState();
}

class _JarvisActionMenuState extends State<JarvisActionMenu> {
  final menu = MenuController();
  LocalHistoryEntry? history;
  void opened() {
    if (JarvisActionMenu._open != menu) JarvisActionMenu.closeOpen();
    JarvisActionMenu._open = menu;
    final route = ModalRoute.of(context);
    if (route != null) {
      history = LocalHistoryEntry(
        onRemove: () {
          history = null;
          if (menu.isOpen) menu.close();
        },
      );
      route.addLocalHistoryEntry(history!);
    }
  }

  void closed() {
    if (JarvisActionMenu._open == menu) JarvisActionMenu._open = null;
    final entry = history;
    history = null;
    entry?.remove();
  }

  @override
  void dispose() {
    closed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      controller: menu,
      // The SDK's animated menu takes 500ms and staggers its rows.
      // Show the surface immediately; reveal all rows together in 100ms.
      animated: false,
      useRootOverlay: true,
      clipBehavior: Clip.antiAlias,
      onOpen: opened,
      onClose: closed,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerHigh),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: colors.outlineVariant)),
      ),
      menuChildren: [
        for (final action in widget.actions)
          _QuickMenuReveal(
            child: MenuItemButton(
              style: ButtonStyle(
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                minimumSize: const WidgetStatePropertyAll(Size(160, 48)),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 12),
                ),
                foregroundColor: WidgetStatePropertyAll(
                  action.destructive ? colors.error : colors.onSurface,
                ),
              ),
              leadingIcon: action.icon == null
                  ? null
                  : Icon(action.icon, size: 18),
              trailingIcon: widget.selectedValue == action.value
                  ? const Icon(Icons.check, size: 18)
                  : null,
              onPressed: () => widget.onSelected(action.value),
              child: Text(action.label),
            ),
          ),
      ],
      builder: (context, controller, _) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        if (widget.child != null) {
          return Tooltip(
            message: widget.tooltip,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: toggle,
                child: widget.child,
              ),
            ),
          );
        }
        return IconButton(
          tooltip: widget.tooltip,
          style: IconButton.styleFrom(
            shape: const CircleBorder(),
            fixedSize: const Size(40, 40),
            minimumSize: const Size(40, 40),
          ),
          onPressed: toggle,
          icon: Icon(Icons.more_horiz, size: widget.iconSize),
        );
      },
    );
  }
}

class _QuickMenuReveal extends StatelessWidget {
  const _QuickMenuReveal({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Duration(
      milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 100,
    ),
    curve: Curves.easeOutCubic,
    child: child,
    builder: (context, value, child) => Opacity(
      opacity: value,
      child: Transform.scale(
        scale: .98 + .02 * value,
        alignment: Alignment.centerLeft,
        child: child,
      ),
    ),
  );
}
