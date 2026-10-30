import 'package:flutter/material.dart';

import 'motion.dart';

/// A small icon button whose icon sits at the very left of its box, so it lines up with the text above it. The press
/// highlight is a circle centred on the icon (ink may paint outside the box), and the tap area (`width` wide, `extent` tall, both 44 by default) extends to the right.
class HuggingIconButton extends StatelessWidget {
  const HuggingIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.iconSize = 16,
    this.extent = 44,
    this.width = 44,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final double iconSize, extent, width;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Padding(
          // The tap area reaches right of the icon (not left, where it would leave the text column).
          padding: EdgeInsets.only(right: width - iconSize),
          child: InkResponse(
            onTap: onPressed,
            radius: extent / 2,
            containedInkWell: false,
            highlightShape: BoxShape.circle,
            child: SizedBox(
              width: iconSize,
              height: extent,
              child: Center(
                // A swapped icon (copy -> check) pops in rather than flipping.
                child: AnimatedSwitcher(
                  duration: motion(context, 150),
                  transitionBuilder: popTransition,
                  child: Icon(
                    icon,
                    key: ValueKey(icon),
                    size: iconSize,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
