import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/services.dart';

import '../voice/voice_session.dart';
import 'design_tokens.dart';
import 'duo_layout.dart';
import 'motion.dart';

/// What a voice row shows about its preview: [loading] from the tap until the first audio is queued, then [playing].
/// The session sets `previewing` at once, so the spinner has to key on `previewLoading`, not on its absence.
class VoicePreviewState {
  const VoicePreviewState._(this.playing, this.loading);
  factory VoicePreviewState.of(VoiceSession v, String voiceId) {
    final mine = v.previewVoice == voiceId;
    return VoicePreviewState._(
      mine && v.previewing && !v.previewLoading,
      mine && v.previewLoading,
    );
  }
  final bool playing, loading;

  /// A tap on the button stops the preview while it loads or plays, and starts it otherwise.
  bool get stops => playing || loading;
}

/// The error to show beside the voice previews: only a failed preview belongs there, the red microphone text of a failed
/// call must not follow the user into the settings or the picker.
String? previewErrorOf(VoiceSession v) => v.previewError;

/// A dialog that stays on one side of the crease when the device is half-folded. `showDialog`'s own safe area is off:
/// [DuoLayout.dialogInsets] works in screen coordinates, and the system strip would be taken off twice (a ~200 pt sliver).
Future<T?> showFoldDialog<T>({
  required BuildContext context,
  required Widget Function(BuildContext context, EdgeInsets insets) builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  useSafeArea: false,
  barrierDismissible: barrierDismissible,
  animationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (context) {
    final duo = DuoLayoutScope.of(context);
    final pad = MediaQuery.paddingOf(context);
    final insets = duo.dialogInsets();
    final pane = duo.foldPane != null, across = duo.horizontalFold != null;
    // The pane and the band below a horizontal fold already sit inside the safe area on those sides.
    return builder(
      context,
      EdgeInsets.fromLTRB(
        insets.left + (pane ? 0 : pad.left),
        insets.top + (across ? 0 : pad.top),
        insets.right + (pane ? 0 : pad.right),
        insets.bottom + pad.bottom,
      ),
    );
  },
);

/// How long a page notice stays: 3 s, longer for a long text (0.12 s a character), never more than 7 s.
Duration noticeDuration(String text) => Duration(
  milliseconds: (math.max(3.0, text.runes.length * .12).clamp(3.0, 7.0) * 1000)
      .round(),
);

/// A notice for a page without the chat's anchor: it lines up with the cards (20 pt side margins), and half-folded in
/// landscape it keeps to the roomy side of the crease instead of spanning it.
void showPageNotice(
  BuildContext context,
  String text, {
  SnackBarAction? action,
}) {
  const side = Metrics.pageMargin;
  final pane = DuoLayoutScope.of(context).foldPane;
  // A floating SnackBar takes the system side insets off a second time; leave that room out of the margins.
  final pad = MediaQuery.paddingOf(context);
  final width = DuoLayoutScope.of(context).size.width;
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(text),
      action: action,
      duration: noticeDuration(text),
      persist: false,
      behavior: SnackBarBehavior.floating,
      margin: pane == null
          ? const EdgeInsets.fromLTRB(side, 0, side, 12)
          : EdgeInsets.fromLTRB(
              math.max(0.0, pane.left + side - pad.left),
              0,
              math.max(0.0, width - pane.right + side - pad.right),
              12,
            ),
    ),
  );
}

/// Full-width closing marks (）」。…) draw in the left half of their square, so a value that ends in one ("16（默认）")
/// stops half a character short of the row's edge, out of line with the values above and below it. This takes that empty
/// half off the last mark's advance (what CSS `text-spacing-trim` does at a line end). Other texts are a plain [Text].
Text flushEndText(
  BuildContext context,
  String value, {
  TextStyle? style,
  TextAlign? textAlign,
  int? maxLines,
  TextOverflow? overflow,
}) {
  const closers = '）」』】〕》〉。，、';
  if (value.isEmpty || !closers.contains(value[value.length - 1])) {
    return Text(
      value,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
  final size = MediaQuery.textScalerOf(
    context,
  ).scale(style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14);
  return Text.rich(
    TextSpan(
      text: value.substring(0, value.length - 1),
      children: [
        TextSpan(
          text: value[value.length - 1],
          style: TextStyle(letterSpacing: -size / 2),
        ),
      ],
    ),
    style: style,
    textAlign: textAlign,
    maxLines: maxLines,
    overflow: overflow,
  );
}

/// A slider in a settings row. The iOS slider draws its track 8 pt inside its own box, so the box reaches 8 pt past the
/// row's text column on each side: the track then starts under the name and ends under the value.
class SettingsSlider extends StatelessWidget {
  const SettingsSlider({super.key, required this.child});
  final Widget child;

  /// The iOS slider's own inset of its track.
  static const bleed = 8.0;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    if (platform != TargetPlatform.iOS && platform != TargetPlatform.macOS) {
      return child;
    }
    return LayoutBuilder(
      builder: (context, box) => OverflowBox(
        minWidth: box.maxWidth + 2 * bleed,
        maxWidth: box.maxWidth + 2 * bleed,
        fit: OverflowBoxFit.deferToChild,
        child: child,
      ),
    );
  }
}

/// A row of a [SettingsGroup] whose text starts somewhere else than the group's [SettingsGroup.dividerIndent]: the
/// hairline under it starts at [dividerIndent] instead.
abstract interface class SettingsRowIndent {
  double get dividerIndent;
}

/// Rounded card that stacks its rows with hairline dividers, the way the system Settings groups rows.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.children,
    this.dividerIndent = 16,
  });
  final List<Widget> children;

  /// Where the hairlines between rows start: 16 for plain rows, 56 under a leading icon (the text start).
  final double dividerIndent;

  /// Text start of a [ListTile] row with a 22 pt icon in a 24 pt slot: 16 + 24 + 16.
  static const iconIndent = 56.0;

  /// Dark keeps the soft grey card. In the light theme that grey is the page colour (#f9faf9), so the card is the
  /// lifted white surface instead.
  static Color fill(ColorScheme colors) => colors.brightness == Brightness.light
      ? colors.surfaceContainerLowest
      : Color.lerp(colors.surfaceContainerLow, colors.surfaceContainer, .35)!;

  /// Card outline and row dividers: a visible hairline on light, Increase Contrast turns it solid and darker.
  static Color line(BuildContext context, ColorScheme colors) {
    if (MediaQuery.highContrastOf(context)) return colors.outline;
    return colors.outlineVariant.withValues(
      alpha: colors.brightness == Brightness.light ? 1 : .5,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final line = SettingsGroup.line(context, colors);
    return Material(
      color: fill(colors),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        side: BorderSide(color: line),
      ),
      // Rows that appear or go (a voice list swapped, an error line) grow and shrink the card instead of jumping.
      child: SmoothSize(
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              // A hairline belongs to the row above it (as in the system lists): a row with its own text column
              // (a voice, after its check mark column) starts the line under its text.
              if (i > 0)
                Divider(
                  height: 1,
                  indent: switch (children[i - 1]) {
                    final SettingsRowIndent row => row.dividerIndent,
                    _ => dividerIndent,
                  },
                  color: line,
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One voice in a list: check mark for the chosen one, name and description, and a play / stop button for the preview.
/// The settings page and the call page's voice picker share it so the two look alike.
class VoiceChoiceRow extends StatelessWidget implements SettingsRowIndent {
  const VoiceChoiceRow({
    super.key,
    required this.name,
    required this.description,
    required this.selected,
    required this.playing,
    required this.onSelect,
    required this.onPlay,
    this.loading = false,
  });
  final String name, description;
  final bool selected, playing;

  /// The preview was asked for and no audio has started yet: a small spinner takes the place of the play icon.
  final bool loading;
  final VoidCallback onSelect, onPlay;

  /// The name's column: 16 pt padding, the check mark's 24 pt slot, 16 pt gap. The same column as the rows with a
  /// leading icon ([SettingsGroup.iconIndent]), and the hairline under the row starts there.
  static const textIndent = SettingsGroup.iconIndent;

  @override
  double get dividerIndent => textIndent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final light = colors.brightness == Brightness.light;
    final accent = JarvisColors.accent(context);
    final tint = Color.lerp(colors.onSurfaceVariant, accent, .55)!;
    // ListTile pads itself by the screen's side safe-area insets (the Dynamic Island in landscape), which would shift
    // the row's content inside its card.
    return MediaQuery.removePadding(
      context: context,
      removeLeft: true,
      removeRight: true,
      // The check mark alone marks the chosen voice (the iOS list convention): no tint across the row, whose edges
      // would not line up with the hairlines that start at the text.
      child: ListTile(
        selected: selected,
        selectedColor: colors.onSurface,
        contentPadding: const EdgeInsets.only(left: 16, right: 8),
        minLeadingWidth: 24,
        horizontalTitleGap: textIndent - 16 - 24,
        leading: SizedBox(
          width: 24,
          height: 40,
          // The chosen voice carries a check mark (the iOS list convention); the others leave the slot empty.
          child: AnimatedSwitcher(
            duration: motion(context, 150),
            transitionBuilder: popTransition,
            child: selected
                ? Icon(
                    Icons.check_rounded,
                    key: const ValueKey('voice-check'),
                    size: 24,
                    color: accent,
                  )
                : const SizedBox.shrink(key: ValueKey('voice-no-check')),
          ),
        ),
        title: Text(name),
        subtitle: description.isEmpty ? null : Text(description),
        onTap: () {
          if (!selected) HapticFeedback.selectionClick();
          onSelect();
        },
        trailing: IconButton.filledTonal(
          // The theme's tonal fill is a flat grey on the card; a light touch of the brand teal sets it apart.
          style: IconButton.styleFrom(
            backgroundColor: accent.withValues(alpha: light ? .09 : .12),
            foregroundColor: tint,
          ),
          tooltip: playing
              ? '停止试听'
              : loading
              ? '正在加载试听'
              : '试听 $name',
          iconSize: 20,
          // Play, loading spinner and stop pop into each other instead of flipping.
          icon: AnimatedSwitcher(
            duration: motion(context, 150),
            transitionBuilder: popTransition,
            child: loading && !playing
                ? JarvisSpinner.inline(
                    key: const ValueKey('voice-loading'),
                    color: tint,
                  )
                : Icon(
                    playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    key: ValueKey(playing ? 'voice-stop' : 'voice-play'),
                  ),
          ),
          onPressed: onPlay,
        ),
      ),
    );
  }
}

/// A small grey heading above a group, with an optional footnote below it.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.footer,
    this.sectionKey,
    this.dividerIndent = 16,
  });
  final String title;
  final List<Widget> children;
  final String? footer;

  /// See [SettingsGroup.dividerIndent].
  final double dividerIndent;
  final Key? sectionKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: sectionKey,
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          SettingsGroup(dividerIndent: dividerIndent, children: children),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Text(
                footer!,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }
}

/// Name on the left, the current value on the right; tapping opens a menu under the row. One tap target;
/// at accessibility text sizes the value moves under the name.
class PickerRow<T> extends StatelessWidget {
  const PickerRow({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onSelected,
  });
  final String label;
  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Nothing to choose from (e.g. the model list has not loaded): the row says so and does not open an empty menu.
    final empty = options.isEmpty;
    final current =
        options.where((o) => o.$1 == value).firstOrNull?.$2 ??
        (empty ? '暂无可选' : null);
    final text = Theme.of(context).textTheme;
    // At accessibility text sizes the label would squeeze the value away: put the value under it.
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 24;
    final name = Text(label, style: text.bodyLarge);
    Widget valueText(TextAlign align) => flushEndText(
      context,
      current ?? '未选择',
      textAlign: align,
      maxLines: stacked ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
    );
    final chevron = Icon(
      Icons.unfold_more_rounded,
      size: 18,
      color: colors.onSurfaceVariant.withValues(
        alpha: empty ? Metrics.disabledOpacity : 1,
      ),
    );
    final menuStyle =
        Theme.of(context).popupMenuTheme.textStyle ?? text.labelLarge;
    final scaler = MediaQuery.textScalerOf(context);
    // The widest option decides the menu width (200 to 320), so the menu can be lined up with the value side.
    var widest = 0.0;
    for (final o in options) {
      final painter = TextPainter(
        text: TextSpan(text: o.$2, style: menuStyle),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return LayoutBuilder(
      builder: (context, box) {
        final menuWidth = (widest + 32 + 30)
            .clamp(200.0, math.max(200.0, math.min(320.0, box.maxWidth - 16)))
            .toDouble();
        // The value sits at the right of the row, so the menu opens under it (its right edge 8 pt inside the row's)
        // instead of under the name. PopupMenuButton cannot do that for a row this wide, hence showMenu.
        void open() {
          if (empty) return;
          final button = context.findRenderObject()! as RenderBox;
          final overlay =
              Navigator.of(context).overlay!.context.findRenderObject()!
                  as RenderBox;
          final corner = button.localToGlobal(Offset.zero, ancestor: overlay);
          var x = corner.dx + box.maxWidth - menuWidth - 8;
          var y = corner.dy + button.size.height;
          // Half-folded the menu keeps to the side of the crease the row is on, and clear of a horizontal crease.
          final duo = DuoLayoutScope.of(context);
          final vertical = duo.verticalFold, across = duo.horizontalFold;
          if (vertical != null) {
            final left = corner.dx + box.maxWidth / 2 < vertical.center.dx;
            final lo = left ? 0.0 : vertical.right;
            final hi = left ? vertical.left : overlay.size.width;
            x = math.max(lo + 8, math.min(x, hi - 8 - menuWidth));
          }
          final menuHeight = options.length * 48.0 + 12;
          if (across != null &&
              y < across.bottom &&
              y + menuHeight > across.top &&
              corner.dy < across.top) {
            y = across.bottom + 8;
          }
          HapticFeedback.selectionClick();
          showMenu<T>(
            context: context,
            position: RelativeRect.fromLTRB(
              x,
              y,
              overlay.size.width - x - menuWidth,
              overlay.size.height - y,
            ),
            initialValue: value,
            color: colors.surfaceContainerHigh,
            // The same surface as the call page's action menu (JarvisActionMenu): radius, outline and a quick reveal.
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.medium),
              side: BorderSide(color: colors.outlineVariant),
            ),
            menuPadding: const EdgeInsets.all(6),
            popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
                ? AnimationStyle.noAnimation
                : AnimationStyle(
                    duration: const Duration(milliseconds: 100),
                    reverseDuration: const Duration(milliseconds: 80),
                    curve: Curves.easeOutCubic,
                  ),
            constraints: BoxConstraints.tightFor(width: menuWidth),
            items: [
              for (final o in options)
                PopupMenuItem<T>(
                  value: o.$1,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          o.$2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (o.$1 == value) ...[
                        const SizedBox(width: 12),
                        Icon(Icons.check, size: 18, color: colors.primary),
                      ],
                    ],
                  ),
                ),
            ],
          ).then((v) {
            if (v == null) return;
            HapticFeedback.selectionClick();
            onSelected(v);
          });
        }

        // One node for the row: name, current value and that it opens a menu.
        return Semantics(
          button: true,
          label: label,
          enabled: !empty,
          value: current ?? '未选择',
          hint: empty ? null : '打开菜单',
          excludeSemantics: true,
          onTap: empty ? null : open,
          child: InkWell(
            onTap: empty ? null : open,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: stacked
                    ? Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [name, valueText(TextAlign.start)],
                            ),
                          ),
                          const SizedBox(width: 4),
                          chevron,
                        ],
                      )
                    : Row(
                        // The name keeps its own width (up to 60% of the row) and the value takes all the rest, flush
                        // right.
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: box.maxWidth * .6,
                            ),
                            child: name,
                          ),
                          const SizedBox(width: 16),
                          Expanded(child: valueText(TextAlign.end)),
                          const SizedBox(width: 4),
                          chevron,
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A switch row with an optional explanation under the name.
class ToggleRow extends StatelessWidget {
  const ToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      // The switch gives its own light impact on iOS (when tapped or dragged); a tap on the rest of the row gives the
      // same one, so both ways of toggling feel alike.
      onTap: () {
        tapFeedback(strong: true);
        onChanged(!value);
      },
      trailing: Switch.adaptive(value: value, onChanged: onChanged),
    ),
  );
}

/// The line above a slider: the name and its current value. At accessibility text sizes the value moves under the name
/// instead of squeezing it (same rule as [PickerRow]).
class SliderHeader extends StatelessWidget {
  const SliderHeader({super.key, required this.title, required this.value});
  final String title, value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 24;
    final name = Text(title, style: text.bodyLarge);
    final current = flushEndText(
      context,
      value,
      style: text.bodyLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [name, current],
      );
    }
    return Row(
      children: [
        Expanded(child: name),
        const SizedBox(width: 12),
        current,
      ],
    );
  }
}

/// A text field that lives in a row: the label on top, the text under it, no box of its own. A tap anywhere on the row
/// focuses the field; while it has the focus the label takes the primary colour and the row a faint tint.
class FieldRow extends StatefulWidget {
  const FieldRow({
    super.key,
    required this.label,
    required this.controller,
    required this.onChanged,
    this.hint,
    this.helper,
    this.error,
    this.minLines = 1,
    this.maxLines = 1,
    this.maxLength,
    this.keyboardType,
    this.inputFormatters,
    this.onTapUpOutside,
    this.focusNode,
    this.textInputAction,
    this.labelAction,
  });
  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String? hint, helper, error;
  final int minLines, maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TapRegionUpCallback? onTapUpOutside;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;

  /// A control at the right end of the label line, e.g. the 完成 key a number pad lacks. The label line is 44 pt high
  /// whether the control is showing or not, so the row does not change height when the field gains the focus.
  final Widget? labelAction;

  /// Height of the label line when it carries a [labelAction] (the touch target size).
  static const actionLineHeight = 44.0;

  @override
  State<FieldRow> createState() => _FieldRowState();
}

class _FieldRowState extends State<FieldRow> {
  FocusNode? _own;
  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void didUpdateWidget(FieldRow old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      _own?.dispose();
      _own = null;
    }
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final label = widget.label;
    final error = widget.error, helper = widget.helper;
    final hasAction = widget.labelAction != null;
    return ListenableBuilder(
      listenable: _node,
      builder: (context, _) {
        final focused = _node.hasFocus;
        // The field below carries the label for assistive technology; reading it twice helps no one.
        final title = ExcludeSemantics(
          child: AnimatedDefaultTextStyle(
            duration: motion(context, 150),
            style: text.bodyLarge!.copyWith(
              color: focused ? colors.primary : colors.onSurface,
            ),
            child: Text(label),
          ),
        );
        // The text sits in the row with no box, so a small pencil at the end of the label line says it can be typed in.
        // It leaves while the field has the focus (the caret says it then) but keeps its room, so nothing moves.
        final pencil = ExcludeSemantics(
          child: AnimatedOpacity(
            key: Key('field-edit-${widget.label}'),
            duration: motion(context, 150),
            opacity: focused ? 0 : 1,
            child: Icon(
              Icons.edit_outlined,
              size: 16,
              color: colors.onSurfaceVariant.withValues(alpha: .8),
            ),
          ),
        );
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          excludeFromSemantics: true,
          onTap: _node.requestFocus,
          child: AnimatedContainer(
            duration: motion(context, 150),
            color: colors.onSurface.withValues(alpha: focused ? .04 : 0),
            // With an action the label line is 44 pt and centred, so its top padding is smaller to put the label where
            // the other rows have it (12 pt from the top).
            padding: EdgeInsets.fromLTRB(16, hasAction ? 2 : 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!hasAction)
                  Row(
                    children: [
                      Expanded(child: title),
                      pencil,
                    ],
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: FieldRow.actionLineHeight,
                    ),
                    child: Row(
                      children: [
                        Expanded(child: title),
                        pencil,
                        widget.labelAction!,
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                Semantics(
                  label: label,
                  textField: true,
                  child: TextField(
                    onTapUpOutside: widget.onTapUpOutside,
                    focusNode: _node,
                    textInputAction: widget.textInputAction,
                    controller: widget.controller,
                    minLines: widget.minLines,
                    maxLines: widget.maxLines,
                    maxLength: widget.maxLength,
                    keyboardType: widget.keyboardType,
                    inputFormatters: widget.inputFormatters,
                    style: text.bodyLarge,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      floatingLabelBehavior: FloatingLabelBehavior.never,
                      hintText: widget.hint,
                      // .8 keeps the hint at 5:1 on the card in light and dark (.7 was 4.1:1), still clearly paler than typed text.
                      hintStyle: text.bodyLarge?.copyWith(
                        color: colors.onSurfaceVariant.withValues(alpha: .8),
                      ),
                      counterStyle: text.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    onChanged: widget.onChanged,
                  ),
                ),
                SmoothSize(
                  alignment: Alignment.topCenter,
                  child: (error ?? helper) == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Semantics(
                            liveRegion: error != null,
                            child: Text(
                              (error ?? helper)!,
                              style: text.bodySmall?.copyWith(
                                color: error != null
                                    ? colors.error
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Shrinks its child a little while a finger is down on it (80 ms in, 160 ms back), the press state of a tappable tile.
/// It only listens to the pointer, so the child's own gestures are untouched.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child});
  final Widget child;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _set(true),
    onPointerUp: (_) => _set(false),
    onPointerCancel: (_) => _set(false),
    child: AnimatedScale(
      scale: _down ? .96 : 1,
      duration: motion(context, _down ? 80 : 160),
      curve: Curves.easeOutCubic,
      child: widget.child,
    ),
  );
}

/// Three little screens: system (split), light and dark. The chosen one has an accent outline.
class ThemeSwatches extends StatelessWidget {
  const ThemeSwatches({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // The resting outline needs 3:1 against the card (a white screen on a white card all but vanishes otherwise).
    final idle = Color.alphaBlend(
      colors.onSurfaceVariant.withValues(alpha: .6),
      SettingsGroup.fill(colors),
    );
    const light = (Color(0xffffffff), Color(0xffd3d8de), Color(0xffe3e6ea));
    const dark = (Color(0xff1d2024), Color(0xff4b5058), Color(0xff343940));
    Widget bars(
      (Color, Color, Color) p, {
      double inset = 10,
      double rightEdge = 10,
    }) => Padding(
      padding: EdgeInsets.fromLTRB(inset, 12, rightEdge, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 7,
            decoration: BoxDecoration(
              color: p.$2,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 6),
          FractionallySizedBox(
            widthFactor: .62,
            child: Container(
              height: 7,
              decoration: BoxDecoration(
                color: p.$3,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
    final options = <(String, String, Widget)>[
      (
        'system',
        '跟随系统',
        Row(
          children: [
            Expanded(
              child: ColoredBox(
                color: light.$1,
                child: SizedBox.expand(child: bars(light, rightEdge: 4)),
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: dark.$1,
                child: SizedBox.expand(child: bars(dark, inset: 4)),
              ),
            ),
          ],
        ),
      ),
      (
        'light',
        '浅色',
        ColoredBox(
          color: light.$1,
          child: SizedBox.expand(child: bars(light)),
        ),
      ),
      (
        'dark',
        '深色',
        ColoredBox(
          color: dark.$1,
          child: SizedBox.expand(child: bars(dark)),
        ),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                button: true,
                selected: value == options[i].$1,
                label: options[i].$2,
                excludeSemantics: true,
                onTap: () => onChanged(options[i].$1),
                child: GestureDetector(
                  key: ValueKey('theme-${options[i].$1}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (value != options[i].$1) {
                      HapticFeedback.selectionClick();
                      onChanged(options[i].$1);
                    }
                  },
                  child: PressScale(
                    child: Column(
                      children: [
                        AnimatedContainer(
                          duration: motion(context),
                          curve: Curves.easeOutCubic,
                          height: 72,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(Radii.small),
                            border: Border.all(
                              width: value == options[i].$1 ? 3 : 1.5,
                              color: value == options[i].$1
                                  ? colors.primary
                                  : idle,
                            ),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  Radii.small - 3,
                                ),
                                child: options[i].$3,
                              ),
                              // Colour alone must not say which one is chosen: the chosen screen also wears a check.
                              Positioned(
                                right: 5,
                                bottom: 5,
                                child: AnimatedScale(
                                  duration: motion(context),
                                  curve: Curves.easeOutBack,
                                  scale: value == options[i].$1 ? 1 : 0,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: colors.primary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(2),
                                      child: Icon(
                                        Icons.check_rounded,
                                        size: 14,
                                        color: colors.onPrimary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        AnimatedDefaultTextStyle(
                          duration: motion(context),
                          style: Theme.of(context).textTheme.bodyMedium!
                              .copyWith(
                                color: value == options[i].$1
                                    ? colors.onSurface
                                    : colors.onSurfaceVariant,
                                fontWeight: value == options[i].$1
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                          child: Text(options[i].$2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Section jump control: one capsule, with a selection that slides to the section on screen.
class SettingsChips extends StatelessWidget {
  const SettingsChips({
    super.key,
    required this.labels,
    required this.active,
    required this.onTap,
  });
  static const height = 52.0;

  /// Height of the soft lower edge of the frosted bar, and where the first section sits at rest (below both).
  static const fade = 20.0;
  static const restInset = height + 6;
  static const capsuleHeight = 44.0;
  static const _pad = 4.0;

  /// The capsule is 44 pt at normal text and grows with Dynamic Type instead of shrinking the labels to fit.
  static double capsuleHeightOf(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium!
        .copyWith(fontWeight: FontWeight.w600);
    final painter = TextPainter(
      text: TextSpan(text: '外观', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final line = painter.height;
    painter.dispose();
    return math.max(capsuleHeight, line + 2 * _pad + 8);
  }

  /// Height of the bar's chips row, and where the first section sits at rest, at the current text size.
  static double heightOf(BuildContext context) =>
      capsuleHeightOf(context) + (height - capsuleHeight);
  static double restInsetOf(BuildContext context) =>
      heightOf(context) + (restInset - height);
  final List<String> labels;
  final ValueListenable<int> active;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.bodyMedium!;
    final capsuleHeight = capsuleHeightOf(context);
    final pill = capsuleHeight - 2 * _pad;
    return SizedBox(
      height: heightOf(context),
      child: Padding(
        // The same side margin as the cards below, so the capsule and the cards share one width.
        padding: const EdgeInsets.symmetric(horizontal: Metrics.pageMargin),
        child: Center(
          child: Container(
            // The hairline border takes 0.5 pt a side: the chips inside keep their full 44 pt.
            height: capsuleHeight + 1,
            padding: const EdgeInsets.symmetric(horizontal: _pad),
            decoration: BoxDecoration(
              color: colors.onSurface.withValues(alpha: .07),
              borderRadius: BorderRadius.circular(capsuleHeight / 2),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: .5),
                width: .5,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, box) {
                final segment = box.maxWidth / labels.length;
                return ValueListenableBuilder<int>(
                  valueListenable: active,
                  builder: (context, current, _) => Stack(
                    // The selection overshoots a little at the ends as it settles.
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedPositioned(
                        duration: motion(context, 360),
                        curve: Curves.easeOutBack,
                        left: current * segment,
                        top: _pad,
                        width: segment,
                        height: pill,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color.alphaBlend(
                              colors.onSurface.withValues(alpha: .16),
                              colors.surface,
                            ),
                            borderRadius: BorderRadius.circular(pill / 2),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          for (var i = 0; i < labels.length; i++)
                            Expanded(
                              child: Semantics(
                                button: true,
                                selected: i == current,
                                excludeSemantics: true,
                                label: labels[i],
                                onTap: () => onTap(i),
                                child: GestureDetector(
                                  key: ValueKey('settings-chip-$i'),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => onTap(i),
                                  // The whole capsule height (44pt) takes the tap, not just the pill.
                                  child: PressScale(
                                    child: SizedBox(
                                      height: capsuleHeight,
                                      child: Center(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: AnimatedDefaultTextStyle(
                                            duration: motion(context),
                                            style: text.copyWith(
                                              color: i == current
                                                  ? colors.onSurface
                                                  : colors.onSurfaceVariant,
                                              fontWeight: i == current
                                                  ? FontWeight.w600
                                                  : FontWeight.w500,
                                            ),
                                            child: Text(labels[i]),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
