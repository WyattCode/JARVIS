import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'motion.dart';

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
    this.semanticLabel,
  });
  final String tooltip;
  final List<JarvisMenuAction> actions;
  final ValueChanged<String> onSelected;
  final Widget? child;
  final String? selectedValue;
  final double iconSize;

  /// What a screen reader says for a custom [child] trigger (its visible text alone, e.g. "思考 · 中", names no
  /// control): spoken as a button, and a double tap opens the menu.
  final String? semanticLabel;
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

  /// The trigger, so the panel knows which side it opens from.
  final anchor = GlobalKey(debugLabel: 'action-menu-trigger');
  LocalHistoryEntry? history;
  ModalRoute<Object?>? historyRoute;
  void opened() {
    if (JarvisActionMenu._open != menu) JarvisActionMenu.closeOpen();
    JarvisActionMenu._open = menu;
    final route = historyRoute = ModalRoute.of(context);
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
    if (JarvisActionMenu._open == menu) JarvisActionMenu._open = null;
    final entry = history, route = historyRoute;
    history = null;
    // Removing the entry dirties the route, which is not allowed while the tree is being unmounted. A route that is
    // gone by then took its entries with it.
    if (entry != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route?.isActive ?? false) entry.remove();
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      controller: menu,
      // The SDK's animated menu takes 500ms and staggers its rows. The SDK's own surface here is invisible and the
      // panel below is the surface: it fades and grows from the trigger's side as one piece, rows and all.
      animated: false,
      useRootOverlay: true,
      clipBehavior: Clip.none,
      // The panel carries a clear [_MenuPanel.edge] margin, so the SDK's fitting (which pushes a menu flush against the
      // safe area) leaves the visible surface that far inside it. This offset takes the margin back out where the menu
      // hangs off its trigger, so there it still lines up with the trigger's edge.
      alignmentOffset: const Offset(-_MenuPanel.edge, -_MenuPanel.edge),
      onOpen: opened,
      onClose: closed,
      style: const MenuStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
      ),
      menuChildren: [
        _MenuPanel(
          anchor: anchor,
          children: [
            for (final action in widget.actions)
              MenuItemButton(
                style: ButtonStyle(
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Radii.small),
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
          ],
        ),
      ],
      builder: (context, controller, _) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        if (widget.child != null) {
          final trigger = Tooltip(
            message: widget.tooltip,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.small),
                onTap: toggle,
                child: widget.child,
              ),
            ),
          );
          final label = widget.semanticLabel;
          return KeyedSubtree(
            key: anchor,
            child: label == null
                ? trigger
                : Semantics(
                    button: true,
                    label: label,
                    onTap: toggle,
                    excludeSemantics: true,
                    child: trigger,
                  ),
          );
        }
        return KeyedSubtree(
          key: anchor,
          child: IconButton(
            tooltip: widget.tooltip,
            style: IconButton.styleFrom(
              shape: const CircleBorder(),
              fixedSize: const Size(44, 44),
              minimumSize: const Size(44, 44),
            ),
            onPressed: toggle,
            icon: Icon(Icons.more_horiz, size: widget.iconSize),
          ),
        );
      },
    );
  }
}

/// The menu's surface and rows, appearing together: fading in while growing from .96, out of the corner that is nearest
/// the trigger.
class _MenuPanel extends StatefulWidget {
  const _MenuPanel({required this.anchor, required this.children});
  final GlobalKey anchor;
  final List<Widget> children;

  /// Least room between the menu and the screen's (safe area's) edges.
  static const edge = 8.0;
  @override
  State<_MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<_MenuPanel> {
  Alignment origin = Alignment.topLeft;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final box = widget.anchor.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      final screen = MediaQuery.sizeOf(context);
      final center = box.localToGlobal(box.size.center(Offset.zero));
      // The menu drops below the trigger, or rises above it when that is nearer the bottom; it lines up with the side
      // of the screen the trigger is on.
      origin = Alignment(
        center.dx > screen.width / 2 ? 1 : -1,
        center.dy > screen.height / 2 ? 1 : -1,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // A clear margin the menu is placed with: the SDK keeps the whole child inside the safe area, so the surface stays
    // [_MenuPanel.edge] clear of the screen's edges. It does not take touches: a tap there still closes the menu.
    return Padding(
      key: const Key('action-menu-margin'),
      padding: const EdgeInsets.all(_MenuPanel.edge),
      // The menu lives in the overlay: without this a tap on a row counts as outside the text field that may be focused
      // underneath (the composer's effort menu) and hides the keyboard.
      child: TextFieldTapRegion(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: motion(context, 120),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.scale(
              scale: .96 + .04 * value,
              alignment: origin,
              child: child,
            ),
          ),
          child: Material(
            color: colors.surfaceContainerHigh,
            surfaceTintColor: Colors.transparent,
            elevation: 3,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.medium),
              side: BorderSide(color: colors.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
