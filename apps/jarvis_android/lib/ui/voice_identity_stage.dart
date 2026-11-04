import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'jarvis_app.dart' show CoreAvatar;
import '../model/fold_proportions.dart';
import 'login_art.dart' show ReactorMode;

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
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final colors = Theme.of(context).textTheme;
      final scaler = MediaQuery.textScalerOf(context);
      final window = MediaQuery.sizeOf(context);
      final tall = window.width < 600 && window.height >= window.width * 1.9;
      final fold = FoldProportions.isFold(window.width, window.height);
      final aspect = fold ? 1.0 : .78;
      final compactSize = fold
          ? FoldProportions.callCompactFigure
          : tall
          ? 120.0
          : 96.0;
      final labelOffset = compactSize + 14;
      final statusStyle = colors.titleMedium!.copyWith(
        fontSize: fold
            ? (compact ? FoldProportions.callStatus : 20)
            : tall
            ? 18
            : null,
        fontWeight: FontWeight.w600,
      );
      final hintStyle = colors.bodySmall!.copyWith(
        fontSize: fold
            ? (compact ? FoldProportions.callHint : 14)
            : tall
            ? 14
            : null,
      );
      ({double height, double width, double baseline}) measure(
        String text,
        TextStyle style,
        double width,
        int lines,
      ) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: lines,
        )..layout(maxWidth: math.max(1, width));
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
      final compactWidth = math.max(1.0, width - labelOffset);
      final gap = windowHeight < 500 ? 6.0 : 12.0;
      final headerBudget = compact
          ? math.max(
              compactSize * aspect,
              height - math.min(minimumTranscriptExtent, height * .65) - gap,
            )
          : double.infinity;
      final inlineGap = fold ? 14.0 : 10.0;
      final naturalStatus = measure(status, statusStyle, compactWidth, 1);
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
          : measure(hint, hintStyle, hintWidth, hintLines).height;
      final labelGap = hintLines == 0 ? 0.0 : 4.0;
      final labelHeight = inline
          ? math.max(statusHeight, baselineDelta + hintHeight)
          : statusHeight + labelGap + hintHeight;
      final waveHeight = waveform == null
          ? 0.0
          : compact
          ? (headerBudget - labelHeight - 8).clamp(0.0, fold ? 16.0 : 36.0)
          : fold
          ? 16.0
          : 40.0;
      final waveGap = waveHeight > 0 ? (fold ? 10.0 : 8.0) : 0.0;
      final identityGap = fold ? FoldProportions.callIdleGap : 14.0;
      final idleHintGap = fold ? FoldProportions.callLabelGap : 8.0;
      final rowHeight = math.max(
        compactSize * aspect,
        labelHeight + waveGap + waveHeight,
      );
      final blockTop = math.max(
        0.0,
        (rowHeight - labelHeight - waveGap - waveHeight) / 2,
      );

      final largeSize = math.min(
        width,
        math.min(
          fold
              ? FoldProportions.callIdleFigure
              : windowHeight < 450
              ? 80.0
              : windowHeight >= 600
              ? 360.0
              : 208.0,
          math.max(
            56.0,
            (height -
                    (fold
                        ? identityGap +
                              statusHeight +
                              idleHintGap +
                              hintHeight +
                              waveGap +
                              waveHeight
                        : 100 * scaler.scale(1))) /
                aspect,
          ),
        ),
      );
      final largeTop = tall
          ? math.max(0.0, height * .06)
          : math.max(
              0.0,
              (height -
                      (largeSize * aspect +
                          identityGap +
                          statusHeight +
                          idleHintGap +
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
            math.max(0, (rowHeight - compactSize * aspect) / 2),
            progress,
          )!;
          final textX = labelOffset * progress;
          final statusY = lerpDouble(
            largeTop + largeSize * aspect + identityGap,
            blockTop,
            progress,
          )!;
          final hintY = lerpDouble(
            largeTop +
                largeSize * aspect +
                identityGap +
                statusHeight +
                idleHintGap,
            blockTop + (inline ? baselineDelta : statusHeight + labelGap),
            progress,
          )!;
          final waveY = lerpDouble(
            largeTop +
                largeSize * aspect +
                identityGap +
                statusHeight +
                idleHintGap +
                hintHeight +
                waveGap,
            blockTop + labelHeight + waveGap,
            progress,
          )!;
          final transcriptTop = lerpDouble(
            height,
            math.min(
              height,
              rowHeight +
                  (fold
                      ? 16
                      : windowHeight < 500
                      ? 6
                      : 12),
            ),
            progress,
          )!;
          return ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: avatarX,
                  top: avatarY,
                  width: size,
                  height: size * aspect,
                  child: Semantics(
                    label: hintLines == 0 ? hint : null,
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
                    child: Text(
                      status,
                      maxLines: statusLines,
                      overflow: TextOverflow.ellipsis,
                      style: statusStyle,
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
                      child: Text(
                        hint,
                        maxLines: hintLines,
                        overflow: TextOverflow.ellipsis,
                        textAlign: progress < .5
                            ? TextAlign.center
                            : TextAlign.start,
                        style: hintStyle,
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
                      widthFactor: fold ? 1 : .9 * .7,
                      alignment: Alignment.center,
                      child: waveform!,
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
