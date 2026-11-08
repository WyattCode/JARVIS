import 'dart:ui' show SemanticsValidationResult;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

bool compactSettings(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width < 600 && size.height < 720;
}

/// Rounded card that stacks its rows with hairline dividers, the way the system Settings groups rows.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});
  final List<Widget> children;

  static Color fill(ColorScheme colors) =>
      Color.lerp(colors.surfaceContainerLow, colors.surfaceContainer, .35)!;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: fill(colors),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 16,
                color: colors.outlineVariant.withValues(alpha: .5),
              ),
            children[i],
          ],
        ],
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
  });
  final String title;
  final List<Widget> children;
  final String? footer;
  final Key? sectionKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: sectionKey,
      padding: EdgeInsets.only(top: compactSettings(context) ? 14 : 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Text(
              title,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SettingsGroup(children: children),
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

/// Name on the left, the current value on the right; tapping opens a menu under the row. One line, one tap target.
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
    final current = options.where((o) => o.$1 == value).firstOrNull?.$2;
    return PopupMenuButton<T>(
      tooltip: label,
      position: PopupMenuPosition.under,
      initialValue: value,
      borderRadius: BorderRadius.circular(16),
      color: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
      onOpened: HapticFeedback.selectionClick,
      onSelected: (v) {
        HapticFeedback.selectionClick();
        onSelected(v);
      },
      itemBuilder: (_) => [
        for (final o in options)
          PopupMenuItem<T>(
            value: o.$1,
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  current ?? '未选择',
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.unfold_more_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
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
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    value: value,
    onChanged: onChanged,
  );
}

/// A text field that lives in a row: the label on top, the text under it, no box of its own.
class FieldRow extends StatelessWidget {
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
    this.onTapOutside,
  });
  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String? hint, helper, error;
  final int minLines, maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TapRegionCallback? onTapOutside;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Text(label, style: text.bodyLarge)),
          const SizedBox(height: 6),
          Semantics(
            label: label,
            hint: error ?? helper,
            validationResult: error == null
                ? SemanticsValidationResult.none
                : SemanticsValidationResult.invalid,
            child: TextField(
              onTapOutside: onTapOutside,
              controller: controller,
              minLines: minLines,
              maxLines: maxLines,
              maxLength: maxLength,
              keyboardType: keyboardType,
              inputFormatters: inputFormatters,
              style: text.bodyLarge,
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(
                    color: error != null
                        ? colors.error
                        : colors.onSurfaceVariant.withValues(alpha: .65),
                  ),
                ),
                errorBorder: InputBorder.none,
                focusedErrorBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: colors.error),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                floatingLabelBehavior: FloatingLabelBehavior.never,
                hintText: hint,
                hintStyle: text.bodyLarge?.copyWith(
                  color: colors.onSurfaceVariant.withValues(alpha: .7),
                ),
                counterStyle: text.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              onChanged: onChanged,
            ),
          ),
          SmoothSize(
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
    );
  }
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
        '系统',
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
        '白天',
        ColoredBox(
          color: light.$1,
          child: SizedBox.expand(child: bars(light)),
        ),
      ),
      (
        'dark',
        '黑夜',
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
                  child: Column(
                    children: [
                      AnimatedContainer(
                        duration: motion(context),
                        curve: Curves.easeOutCubic,
                        height: compactSettings(context) ? 56 : 72,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            width: 2,
                            color: value == options[i].$1
                                ? colors.primary
                                : colors.outlineVariant,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(11),
                          child: options[i].$3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      AnimatedDefaultTextStyle(
                        duration: motion(context),
                        style: Theme.of(context).textTheme.bodyMedium!.copyWith(
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
    this.margin = 20,
  });
  static const height = 52.0;

  /// Height of the soft lower edge of the frosted bar, and where the first section sits at rest (below both).
  static const fade = 20.0;
  static const restInset = height + 6;
  static const capsuleHeight = 44.0;
  static const _pad = 4.0;
  final List<String> labels;
  final ValueListenable<int> active;
  final ValueChanged<int> onTap;

  /// The side margin round the capsule (the cards' own).
  final double margin;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.bodyMedium!;
    const pill = capsuleHeight - 2 * _pad;
    return SizedBox(
      height: height,
      child: Padding(
        // The same side margin as the cards below, so the capsule and the cards share one width.
        padding: EdgeInsets.symmetric(horizontal: margin),
        child: Center(
          child: Container(
            height: capsuleHeight,
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
