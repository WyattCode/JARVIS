import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design_tokens.dart';

class VoiceModeSelector extends StatelessWidget {
  const VoiceModeSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.short = false,
  });
  final String value;
  final ValueChanged<String> onChanged;

  /// The short (landscape) layout: see [heightFor].
  final bool short;

  /// The call controls' one height: the selector and the talk button beside or under it are this tall (56, and 54 on a
  /// short screen, where the choices keep their 44 pt touch height).
  static double heightFor(bool short) => short ? 54 : 56;

  /// The 4 pt inset plus the 1 pt outline on each side.
  static const _frame = 10.0;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Increase Contrast: the outlines turn solid, like the settings cards.
    final contrast = MediaQuery.highContrastOf(context);
    final style = Theme.of(context).textTheme.labelLarge!
        .copyWith(fontSize: 14, fontWeight: FontWeight.w600);
    Widget choice(String id, String label) => Semantics(
      selected: value == id,
      child: TextButton.icon(
        key: ValueKey('voice-mode-$id'),
        onPressed: () {
          if (value != id) HapticFeedback.selectionClick();
          onChanged(id);
        },
        style: TextButton.styleFrom(
          // The choice fills the frame exactly (no extra tap-target band), so the selector is [heightFor] tall.
          minimumSize: Size(0, heightFor(short) - _frame),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          backgroundColor: value == id
              ? colors.surfaceContainerHighest
              : Colors.transparent,
          foregroundColor: value == id
              ? colors.onSurface
              : colors.onSurfaceVariant,
          side: BorderSide(
            color: value == id
                ? colors.outline.withValues(alpha: contrast ? 1 : .65)
                : Colors.transparent,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.small),
          ),
          textStyle: style,
        ),
        icon: Icon(
          value == id
              ? Icons.check_circle_outline
              : id == 'ptt'
              ? Icons.touch_app_outlined
              : Icons.hearing_outlined,
          size: 16,
        ),
        label: Text(label, maxLines: 2, textAlign: TextAlign.center),
      ),
    );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.medium),
        border: Border.all(
          color: contrast
              ? colors.outline
              : colors.outlineVariant.withValues(alpha: .7),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final text = TextPainter(
            text: TextSpan(text: '按住说话', style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final needed = (text.width + 42) * 2 + 4;
          text.dispose();
          if (bounds.maxWidth < needed) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                choice('ptt', '按住说话'),
                const SizedBox(height: 4),
                choice('vad', '免按对话'),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: choice('ptt', '按住说话')),
              const SizedBox(width: 4),
              Expanded(child: choice('vad', '免按对话')),
            ],
          );
        },
      ),
    );
  }
}
