import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'menu_layout.dart';
import 'page_palette.dart';

class JarvisMenuAction {
  const JarvisMenuAction(
    this.value,
    this.label, {
    this.icon,
    this.destructive = false,
    this.selected,
  });
  final String value, label;
  final IconData? icon;
  final bool destructive;

  /// Whether this is the row in use (a check and a pill behind it). Null
  /// leaves that to the menu's `selectedValue`.
  final bool? selected;

  /// The icons of the thinking-depth menu's rows.
  static const effortIcons = <String, IconData>{
    'none': Icons.block,
    'low': Icons.bolt,
    'medium': Icons.lightbulb_outline,
    'high': Icons.psychology,
  };
}

/// Shared action surface, with native Back dismissing the menu before its page.
///
/// The panel is a layer over the window rather than a page, so the keyboard
/// stays up and nothing under it moves. A menu on a labelled button
/// ([child]) hangs above it with a round chip behind each icon and a 34 corner
/// (the iOS button menu); a menu on the bar's own button opens below it.
class JarvisActionMenu extends StatefulWidget {
  const JarvisActionMenu({
    super.key,
    required this.tooltip,
    required this.actions,
    required this.onSelected,
    this.child,
    this.selectedValue,
    this.iconSize = 20,
    this.above,
  });
  final String tooltip;
  final List<JarvisMenuAction> actions;
  final ValueChanged<String> onSelected;
  final Widget? child;
  final String? selectedValue;
  final double iconSize;

  /// Whether the panel hangs above the anchor; by default it does for a menu
  /// on a [child] and opens below the bar's own button.
  final bool? above;
  static _JarvisActionMenuState? _open;
  static bool get isOpen => _open?.open == true;
  static bool closeOpen() {
    final menu = _open;
    if (menu == null || !menu.open) return false;
    menu.close();
    return true;
  }

  @override
  State<JarvisActionMenu> createState() => _JarvisActionMenuState();
}

class _JarvisActionMenuState extends State<JarvisActionMenu>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final portal = OverlayPortalController();
  late final AnimationController motion = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );
  LocalHistoryEntry? history;
  bool open = false;
  Rect anchor = Rect.zero;
  Size window = Size.zero;

  bool get fit => widget.child != null;
  bool get above => widget.above ?? fit;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// A turn or a fold makes the place it hangs from the wrong one.
  @override
  void didChangeMetrics() {
    if (open && mounted && viewSize() != window) close(animated: false);
  }

  Size viewSize() {
    final view = View.of(context);
    return view.physicalSize / view.devicePixelRatio;
  }

  void show() {
    if (open) return;
    if (JarvisActionMenu._open != this) JarvisActionMenu.closeOpen();
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    anchor = box.localToGlobal(Offset.zero) & box.size;
    window = viewSize();
    open = true;
    JarvisActionMenu._open = this;
    final route = ModalRoute.of(context);
    if (route != null) {
      history = LocalHistoryEntry(
        onRemove: () {
          history = null;
          if (open) close();
        },
      );
      route.addLocalHistoryEntry(history!);
    }
    HapticFeedback.mediumImpact();
    portal.show();
    if (MediaQuery.disableAnimationsOf(context)) {
      motion.value = 1;
    } else {
      // It opens from the corner it hangs from: a spring that grows out of
      // the anchor.
      motion.value = 0;
      motion.animateWith(
        SpringSimulation(
          SpringDescription.withDampingRatio(
            mass: 1,
            stiffness: 150,
            ratio: .72,
          ),
          0,
          1,
          .6,
        ),
      );
    }
    setState(() {});
  }

  void close({bool animated = true}) {
    if (!open) return;
    open = false;
    if (JarvisActionMenu._open == this) JarvisActionMenu._open = null;
    final entry = history;
    history = null;
    entry?.remove();
    if (!animated ||
        !mounted ||
        MediaQuery.disableAnimationsOf(context) ||
        !portal.isShowing) {
      motion.stop();
      if (portal.isShowing) portal.hide();
      return;
    }
    motion
        .animateTo(
          0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeIn,
        )
        .whenComplete(() {
          if (!open && portal.isShowing) portal.hide();
        });
  }

  void choose(JarvisMenuAction action) {
    if (!open) return;
    HapticFeedback.lightImpact();
    widget.onSelected(action.value);
    close();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    open = false;
    if (JarvisActionMenu._open == this) JarvisActionMenu._open = null;
    final entry = history;
    history = null;
    entry?.remove();
    motion.dispose();
    super.dispose();
  }

  IconData? iconOf(JarvisMenuAction action) {
    if (action.icon != null) return action.icon;
    // The thinking-depth menu's rows carry their own icons.
    return widget.actions.every(
          (a) => JarvisMenuAction.effortIcons.containsKey(a.value),
        )
        ? JarvisMenuAction.effortIcons[action.value]
        : null;
  }

  Widget overlay(BuildContext context) {
    final media = MediaQuery.of(context);
    final view = MediaQueryData.fromView(View.of(context));
    final whole = Offset.zero & view.size;
    final inset = view.padding.deflateRect(view.viewInsets.deflateRect(whole));
    final screens = DisplayFeatureSubScreen.subScreensInBounds(
      inset,
      DisplayFeatureSubScreen.avoidBounds(media),
    );
    var usable = screens.first;
    for (final s in screens) {
      if ((s.center - anchor.center).distance <
          (usable.center - anchor.center).distance) {
        usable = s;
      }
    }
    final p = PagePalette.of(context);
    final colors = Theme.of(context).colorScheme;
    final selectedValue = widget.selectedValue;
    final radius = fit ? 34.0 : 26.0;
    final alignLeft = fit;
    final panel = Material(
      key: const Key('action-menu-panel'),
      color: colors.surfaceContainerHigh,
      elevation: 8,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: p.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 190),
        child: IntrinsicWidth(
          child: Padding(
            padding: EdgeInsets.all(fit ? 8 : 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final action in widget.actions)
                  _MenuRow(
                    key: ValueKey('menu-row-${action.value}'),
                    action: action,
                    icon: iconOf(action),
                    chip: fit,
                    selected: action.selected ?? selectedValue == action.value,
                    onTap: () => choose(action),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return BlockSemantics(
      child: Stack(
        children: [
          // A touch anywhere else closes it.
          Positioned.fill(
            child: GestureDetector(
              key: const Key('action-menu-barrier'),
              behavior: HitTestBehavior.opaque,
              onTap: close,
              onSecondaryTap: close,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: MenuLayout(
                anchor: anchor,
                usable: usable,
                above: above,
                alignLeft: alignLeft,
              ),
              child: AnimatedBuilder(
                animation: motion,
                child: panel,
                builder: (context, child) {
                  final v = motion.value;
                  return Opacity(
                    opacity: (v * 3).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: .72 + .28 * v,
                      alignment: Alignment(alignLeft ? -1 : 1, above ? 1 : -1),
                      child: child,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget anchorWidget() {
      void toggle() => open ? close() : show();
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
    }

    return OverlayPortal(
      overlayLocation: OverlayChildLocation.rootOverlay,
      controller: portal,
      overlayChildBuilder: overlay,
      child: anchorWidget(),
    );
  }
}

/// A row of the panel: 17pt text, an icon (in a round chip on a button's
/// menu), and, on the row in use, a pill of 12% of the text colour behind it
/// and an accent check at the end.
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    super.key,
    required this.action,
    required this.icon,
    required this.chip,
    required this.selected,
    required this.onTap,
  });
  final JarvisMenuAction action;
  final IconData? icon;
  final bool chip, selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = PagePalette.of(context);
    final color = action.destructive ? p.error : p.onSurface;
    final pill = BorderRadius.circular(chip ? 30 : 18);
    return Semantics(
      button: true,
      selected: selected,
      container: true,
      child: Material(
        color: selected
            ? p.onSurface.withValues(alpha: .12)
            : Colors.transparent,
        borderRadius: pill,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: chip
                ? EdgeInsetsDirectional.fromSTEB(8, 8, selected ? 16 : 26, 8)
                : EdgeInsetsDirectional.fromSTEB(
                    16,
                    12,
                    selected ? 16 : 22,
                    12,
                  ),
            child: Row(
              children: [
                if (icon != null) ...[
                  chip
                      ? Container(
                          key: ValueKey('menu-chip-${action.value}'),
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: p.onSurface.withValues(alpha: .10),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(icon, size: 20, color: color),
                        )
                      : Icon(icon, size: 20, color: color),
                  SizedBox(width: chip ? 16 : 12),
                ],
                Expanded(
                  child: Text(
                    action.label,
                    style: TextStyle(fontSize: 17, color: color),
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 24),
                  Icon(
                    Icons.check,
                    key: ValueKey('menu-check-${action.value}'),
                    size: 18,
                    color: p.accent,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
