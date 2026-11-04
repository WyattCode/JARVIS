import 'package:flutter/material.dart';

class VoiceModeSelector extends StatelessWidget {
  const VoiceModeSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final String value;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelLarge!
        .copyWith(fontSize: 14, fontWeight: FontWeight.w600);
    Widget choice(String id, String label) => Semantics(
      selected: value == id,
      label: id == 'ptt' ? '按住说话模式' : '免按对话模式',
      child: TextButton.icon(
        key: ValueKey('voice-mode-$id'),
        onPressed: () => onChanged(id),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          backgroundColor: value == id
              ? colors.surfaceContainerHighest
              : Colors.transparent,
          foregroundColor: value == id
              ? colors.onSurface
              : colors.onSurfaceVariant,
          side: BorderSide(
            color: value == id
                ? colors.outline.withValues(alpha: .65)
                : Colors.transparent,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
          textStyle: style,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .7)),
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
                choice('ptt', '按住'),
                const SizedBox(height: 4),
                choice('vad', '免按'),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: choice('ptt', '按住')),
              const SizedBox(width: 4),
              Expanded(child: choice('vad', '免按')),
            ],
          );
        },
      ),
    );
  }
}
