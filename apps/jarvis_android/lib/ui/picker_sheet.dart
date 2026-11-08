import 'package:flutter/material.dart';

import 'page_palette.dart';

/// A sheet as the iOS pages present them (the page sheet with the medium and
/// large detents): the card colour, a top corner of 24, open at half the
/// window's height, drawn up to all of it, and closed by drawing it down.
/// [builder] gets the controller its scrolling content must use, so that the
/// content and the sheet share one drag.
Future<T?> showPickerSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext context, ScrollController scroll)
  builder,
  RouteSettings? routeSettings,
}) {
  final p = PagePalette.of(context);
  return showModalBottomSheet<T>(
    context: context,
    routeSettings: routeSettings,
    isScrollControlled: true,
    useSafeArea: true,
    // The sheet's own drag (below) moves it between the two heights and closes
    // it from the lower one.
    enableDrag: false,
    backgroundColor: p.card,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .5,
      // Below the lower height only so that drawing the sheet down reaches a
      // size that closes it; it snaps to the half or the whole.
      minChildSize: .25,
      maxChildSize: 1,
      snap: true,
      snapSizes: const [.5, 1],
      shouldCloseOnMinExtent: true,
      builder: builder,
    ),
  );
}

/// The small bar at the top of a sheet.
class PickerGrabber extends StatelessWidget {
  const PickerGrabber({super.key});

  @override
  Widget build(BuildContext context) {
    final p = PagePalette.of(context);
    return Center(
      child: Container(
        key: const Key('sheet-grabber'),
        margin: const EdgeInsets.only(top: 8),
        width: 36,
        height: 5,
        decoration: BoxDecoration(
          color: p.onSurfaceVariant.withValues(alpha: .4),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}

/// A sheet's title: 20pt semibold, 22 from the sides, 22 above and 4 below.
class PickerTitle extends StatelessWidget {
  const PickerTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = PagePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 4),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: p.onSurface,
          ),
        ),
      ),
    );
  }
}
