import 'package:flutter/material.dart';

/// The glyph starts at the reply text edge while the full target stays 44dp.
class ReplyActionButton extends StatelessWidget {
  const ReplyActionButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    alignment: Alignment.centerLeft,
    padding: EdgeInsets.zero,
    style: IconButton.styleFrom(
      minimumSize: const Size(48, 48),
      fixedSize: const Size(48, 48),
      shape: const CircleBorder(),
    ),
    icon: Icon(
      icon,
      size: 16,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
