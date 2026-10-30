import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'duo_layout.dart';
import 'jarvis_app.dart' show CoreAvatar;
import 'login_art.dart' show ReactorMode;
import 'motion.dart';

/// One retained reactor moves from welcome to transcript; no cross-faded clones.
class VoiceIdentityStage extends StatelessWidget {
  const VoiceIdentityStage({
    super.key,
    required this.compact,
    required this.windowHeight,
    required this.identity,
    required this.status,
    required this.hint,
    required this.mode,
    required this.onTap,
    required this.transcript,
    this.minimumTranscriptExtent = 72,
    this.waveform,
    this.hintIsError = false,
    this.onVerticalDragStart,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
    this.onVerticalDragCancel,
  });
  final bool compact;
  final double windowHeight;
  final Object? identity;
  final String status, hint;
  final ReactorMode mode;
  final VoidCallback onTap;
  final Widget transcript;
  final double minimumTranscriptExtent;
  final Widget? waveform;

  /// A vertical drag on the avatar and the text above the transcript (which scrolls and is left out) is reported here.
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  final GestureDragCancelCallback? onVerticalDragCancel;

  /// The status words of a call. The line they share with the hint reserves the width of the widest, so the hint does not
  /// jump sideways every time the status changes.
  static const statusVocabulary = ['正在聆听', '思考中', '正在回答', '已静音', '已就绪'];

  /// The hint is an error message: error colour, a warning icon, announced by screen readers when it appears.
  final bool hintIsError;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final colors = Theme.of(context).textTheme;
      final scaler = MediaQuery.textScalerOf(context);
      final window = MediaQuery.sizeOf(context);
      final tall = window.width < 600 && window.height >= window.width * 1.9;
      final compactSize = tall ? 120.0 : 96.0;
      final labelOffset = compactSize + 14;
      final statusStyle = colors.titleMedium!.copyWith(
        fontSize: tall ? 18 : null,
      );
      final error = Theme.of(context).colorScheme.error;
      final hintStyle = colors.bodySmall!.copyWith(
        fontSize: tall ? 14 : null,
        color: hintIsError ? error : null,
      );
      // An error hint leads with a small icon; the painter needs its size to wrap the text the way the Text will.
      InlineSpan hintSpan(String text, TextStyle style) => hintIsError
          ? TextSpan(
              style: style,
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.error_outline,
                      size: (style.fontSize ?? 12) + 2,
                      color: error,
                    ),
                  ),
                ),
                TextSpan(text: text),
              ],
            )
          : TextSpan(text: text, style: style);
      ({double height, double width, double baseline}) measure(
        String text,
        TextStyle style,
        double width,
        int lines, {
        bool hint = false,
      }) {
        final painter = TextPainter(
          text: hint
              ? hintSpan(text, style)
              : TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: lines,
        );
        if (hint && hintIsError) {
          final icon = (style.fontSize ?? 12) + 2 + 4;
          painter.setPlaceholderDimensions([
            PlaceholderDimensions(
              size: Size(icon, icon),
              alignment: PlaceholderAlignment.middle,
            ),
          ]);
        }
        painter.layout(maxWidth: math.max(1, width));
        final result = (
          height: painter.height,
          width: painter.width,
          baseline: painter.computeDistanceToActualBaseline(
            TextBaseline.alphabetic,
          ),
        );
        painter.dispose();
        return result;
      }

      final width = bounds.maxWidth, height = bounds.maxHeight;
      // Only a reply in progress can be interrupted.
      final interruptible =
          mode == ReactorMode.speaking || mode == ReactorMode.thinking;
      final compactWidth = math.max(1.0, width - labelOffset);
      final gap = windowHeight < 500 ? 6.0 : 12.0;
      final headerBudget = compact
          ? math.max(
              compactSize * .78,
              height - math.min(minimumTranscriptExtent, height * .65) - gap,
            )
          : double.infinity;
      const inlineGap = 10.0;
      final measured = measure(status, statusStyle, compactWidth, 1);
      final naturalStatus = (
        height: measured.height,
        baseline: measured.baseline,
        width: statusVocabulary.fold<double>(
          measured.width,
          (widest, word) => math.max(
            widest,
            measure(word, statusStyle, compactWidth, 1).width,
          ),
        ),
      );
      // Keep normal-size labels on one baseline; large accessibility text can
      // use the stacked layout rather than squeeze the explanation to nothing.
      final inline =
          compact &&
          compactWidth >= naturalStatus.width + inlineGap + scaler.scale(64);
      final statusWidth = inline ? naturalStatus.width : compactWidth;
      final statusLines =
          inline ||
              (compact &&
                  measure(status, statusStyle, compactWidth, 2).height >
                      headerBudget * .5)
          ? 1
          : 2;
      final statusMetrics = measure(
        status,
        statusStyle,
        statusWidth,
        statusLines,
      );
      final statusHeight = statusMetrics.height;
      final hintWidth = inline
          ? math.max(1.0, compactWidth - statusWidth - inlineGap)
          : compactWidth;
      final hintLine = measure('字', hintStyle, hintWidth, 1);
      final baselineDelta = inline
          ? math.max(0.0, statusMetrics.baseline - hintLine.baseline)
          : 0.0;
      final hintLines = compact
          ? ((headerBudget - (inline ? baselineDelta : statusHeight + 4)) /
                    hintLine.height)
                .floor()
                .clamp(0, windowHeight < 500 ? 2 : 3)
          : (windowHeight < 500 ? 2 : 3);
      final hintHeight = hintLines == 0
          ? 0.0
          : measure(hint, hintStyle, hintWidth, hintLines, hint: true).height;
      final labelGap = hintLines == 0 ? 0.0 : 4.0;
      final labelHeight = inline
          ? math.max(statusHeight, baselineDelta + hintHeight)
          : statusHeight + labelGap + hintHeight;
      final waveHeight = waveform == null
          ? 0.0
          : compact
          ? (headerBudget - labelHeight - 8).clamp(0.0, 36.0)
          : 40.0;
      final waveGap = waveHeight > 0 ? 8.0 : 0.0;
      final rowHeight = math.max(
        compactSize * .78,
        labelHeight + waveGap + waveHeight,
      );
      final blockTop = math.max(
        0.0,
        (rowHeight - labelHeight - waveGap - waveHeight) / 2,
      );

      // Half-folded the stage is only one side of the window wide: the avatar never outgrows it.
      final largeSize = math.min(
        width,
        math.min(
          windowHeight < 450
              ? 80.0
              : windowHeight >= 600
              ? math.min(
                  MediaQuery.sizeOf(context).width - 40,
                  MediaQuery.sizeOf(context).height >=
                          MediaQuery.sizeOf(context).width * 1.9
                      ? 360.0
                      : 320.0,
                )
              : 208.0,
          math.max(56.0, (height - 100 * scaler.scale(1)) / .78),
        ),
      );
      final largeTop = tall
          ? math.max(0.0, height * .06)
          : math.max(
              0.0,
              (height -
                      (largeSize * .78 +
                          14 +
                          statusHeight +
                          8 +
                          hintHeight +
                          waveGap +
                          waveHeight)) *
                  .30,
            );
      return TweenAnimationBuilder<double>(
        tween: Tween(end: compact ? 1 : 0),
        duration: Duration(
          milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 480,
        ),
        curve: Curves.easeInOutCubic,
        builder: (context, progress, _) {
          final size = lerpDouble(largeSize, compactSize, progress)!;
          final avatarX = lerpDouble((width - largeSize) / 2, 0, progress)!;
          final avatarY = lerpDouble(
            largeTop,
            math.max(0, (rowHeight - compactSize * .78) / 2),
            progress,
          )!;
          final textX = labelOffset * progress;
          final statusY = lerpDouble(
            largeTop + largeSize * .78 + 14,
            blockTop,
            progress,
          )!;
          final hintY = lerpDouble(
            largeTop + largeSize * .78 + 14 + statusHeight + 8,
            blockTop + (inline ? baselineDelta : statusHeight + labelGap),
            progress,
          )!;
          final waveY = lerpDouble(
            largeTop +
                largeSize * .78 +
                14 +
                statusHeight +
                8 +
                hintHeight +
                waveGap,
            blockTop + labelHeight + waveGap,
            progress,
          )!;
          final transcriptTop = lerpDouble(
            height,
            math.min(height, rowHeight + (windowHeight < 500 ? 6 : 12)),
            progress,
          )!;
          return ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: avatarX,
                  top: avatarY,
                  width: size,
                  height: size * .78,
                  child: Semantics(
                    // A reply that is playing (or being thought out) can be cut off; while idle there is nothing to
                    // interrupt, so the avatar is not offered as a button then. The hint still rides along when it is
                    // not shown as text.
                    button: interruptible,
                    label: interruptible
                        ? '打断回复'
                        : (hintLines == 0 ? hint : null),
                    value: interruptible && hintLines == 0 ? hint : null,
                    onTap: interruptible ? onTap : null,
                    excludeSemantics: true,
                    child: GestureDetector(
                      onTap: onTap,
                      child: CoreAvatar(
                        key: ValueKey('voice-reactor-$identity'),
                        size: size,
                        mode: mode,
                        motionSpeed: 1.2,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: textX,
                  right: inline ? (compactWidth - statusWidth) * progress : 0,
                  top: statusY,
                  child: Align(
                    alignment: Alignment.lerp(
                      Alignment.center,
                      Alignment.centerLeft,
                      progress,
                    )!,
                    // Screen readers announce 正在聆听 / 思考中 / 正在回答 as the call moves on.
                    child: Semantics(
                      liveRegion: true,
                      child: AnimatedSwitcher(
                        duration: motion(context, 160),
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.lerp(
                            Alignment.center,
                            Alignment.centerLeft,
                            progress,
                          )!,
                          children: [...previous, ?current],
                        ),
                        child: Text(
                          status,
                          key: ValueKey(status),
                          maxLines: statusLines,
                          overflow: TextOverflow.ellipsis,
                          style: statusStyle,
                        ),
                      ),
                    ),
                  ),
                ),
                if (hintLines > 0)
                  Positioned(
                    left:
                        textX +
                        (inline ? (statusWidth + inlineGap) * progress : 0),
                    right: 0,
                    top: hintY,
                    child: Align(
                      alignment: Alignment.lerp(
                        Alignment.center,
                        Alignment.centerLeft,
                        progress,
                      )!,
                      child: Semantics(
                        liveRegion: hintIsError,
                        child: AnimatedSwitcher(
                          duration: motion(context, 160),
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.lerp(
                              Alignment.center,
                              Alignment.centerLeft,
                              progress,
                            )!,
                            children: [...previous, ?current],
                          ),
                          child: Text.rich(
                            hintSpan(hint, hintStyle),
                            key: ValueKey((hint, hintIsError)),
                            maxLines: hintLines,
                            overflow: TextOverflow.ellipsis,
                            textAlign: progress < .5
                                ? TextAlign.center
                                : TextAlign.start,
                            style: hintStyle,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (waveHeight > 0)
                  Positioned(
                    left: textX,
                    right: 0,
                    top: waveY,
                    height: waveHeight,
                    child: FractionallySizedBox(
                      // Foldable iPhone: the waveform strip is 30% shorter.
                      widthFactor: DuoLayoutScope.of(context).isFoldable
                          ? .9 * .7
                          : .9,
                      // Foldable: once the avatar sits at the left the waveform starts where the text starts, so
                      // avatar, status, hint and waveform read as one block (centred as one block when large).
                      alignment: DuoLayoutScope.of(context).isFoldable
                          ? Alignment.lerp(
                              Alignment.center,
                              Alignment.centerLeft,
                              progress,
                            )!
                          : Alignment.center,
                      child: waveform!,
                    ),
                  ),
                if (onVerticalDragUpdate != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: transcriptTop,
                    // Over the avatar and the text but see-through to them: a tap on the avatar still interrupts.
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragStart: onVerticalDragStart,
                      onVerticalDragUpdate: onVerticalDragUpdate,
                      onVerticalDragEnd: onVerticalDragEnd,
                      onVerticalDragCancel: onVerticalDragCancel,
                      child: const SizedBox.expand(),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: transcriptTop,
                  bottom: 0,
                  child: ExcludeSemantics(
                    excluding: progress < .85,
                    child: IgnorePointer(
                      ignoring: progress < .85,
                      child: Opacity(
                        opacity: ((progress - .2) / .8).clamp(0.0, 1.0),
                        child: transcript,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
