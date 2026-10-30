import 'package:flutter/material.dart';

import 'motion.dart';

/// The app's shared design values. New UI uses these instead of its own numbers.
abstract final class Radii {
  /// Blocks inside a card, menu rows, small tiles.
  static const small = 12.0;

  /// Cards, grouped lists, menus, snackbars, buttons.
  static const medium = 16.0;

  /// Large controls and message bubbles.
  static const large = 20.0;

  /// Sheets and dialogs.
  static const sheet = 24.0;
}

abstract final class Metrics {
  /// Side margin of a settings-like page and of a sheet's content.
  static const pageMargin = 20.0;

  /// Opacity of a disabled control.
  static const disabledOpacity = .38;

  /// Spinner sizes: beside text, inside a button, for a whole page.
  static const spinnerInline = 14.0, spinnerButton = 18.0, spinnerPage = 28.0;
}

/// The one loading indicator: a thin ring, in the size that fits where it sits.
class JarvisSpinner extends StatelessWidget {
  const JarvisSpinner.inline({super.key, this.color, this.semanticsLabel})
    : size = Metrics.spinnerInline,
      strokeWidth = 2;
  const JarvisSpinner.button({super.key, this.color, this.semanticsLabel})
    : size = Metrics.spinnerButton,
      strokeWidth = 2;
  const JarvisSpinner.page({super.key, this.color, this.semanticsLabel})
    : size = Metrics.spinnerPage,
      strokeWidth = 2.5;
  final double size, strokeWidth;
  final Color? color;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CircularProgressIndicator(
      strokeWidth: strokeWidth,
      color: color,
      semanticsLabel: semanticsLabel,
    ),
  );
}

/// Status colours shared by the whole app. The accent keeps 4.5:1 or more on the light page, cards and dialogs
/// (4.5 to 5.3:1) and over 10:1 on the dark ones, so it can colour text.
abstract final class JarvisColors {
  static Color accent(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xff8fdceb)
      : const Color(0xff137589);
  static Color success(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xff2d9f80)
      : const Color(0xff1f7a5f);
  static Color warning(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xffc6a765)
      : const Color(0xff8a6d1f);

  /// The hang-up button's red.
  static const danger = Color(0xffaf3543);
}

/// An error under a control or a list: icon and message, easing in and out, announced to a screen reader.
class InlineError extends StatelessWidget {
  const InlineError(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 0),
  });
  final String? text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final message = text;
    return SmoothSize(
      milliseconds: 180,
      alignment: Alignment.topCenter,
      child: message == null || message.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: padding,
              child: Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.error_outline,
                        size: 16,
                        color: colors.error,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        message,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
