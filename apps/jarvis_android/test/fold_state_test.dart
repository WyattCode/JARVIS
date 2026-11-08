import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/adaptive_layout.dart';
import 'package:jarvis_android/model/fold_state.dart';

DisplayFeature crease(
  Rect bounds, {
  DisplayFeatureState state = DisplayFeatureState.postureHalfOpened,
  DisplayFeatureType type = DisplayFeatureType.fold,
}) => DisplayFeature(bounds: bounds, type: type, state: state);

void main() {
  group('FoldState.fromFeatures', () {
    test('no features, or only a cutout, is no fold', () {
      expect(FoldState.fromFeatures(const []), FoldState.none);
      expect(
        FoldState.fromFeatures([
          crease(
            const Rect.fromLTWH(0, 0, 100, 30),
            type: DisplayFeatureType.cutout,
            state: DisplayFeatureState.unknown,
          ),
        ]),
        FoldState.none,
      );
    });

    test('reads posture and bounds from a fold or a hinge', () {
      const bounds = Rect.fromLTWH(425, 0, 10, 608);
      final half = FoldState.fromFeatures([crease(bounds)]);
      expect(half.posture, FoldPosture.halfOpened);
      expect(half.bounds, bounds);
      final flat = FoldState.fromFeatures([
        crease(
          bounds,
          state: DisplayFeatureState.postureFlat,
          type: DisplayFeatureType.hinge,
        ),
      ]);
      expect(flat.posture, FoldPosture.flat);
      // A fold whose angle is not reported is not treated as half-open.
      final unknown = FoldState.fromFeatures([
        crease(bounds, state: DisplayFeatureState.unknown),
      ]);
      expect(unknown.posture, FoldPosture.flat);
    });

    test(
      'the crease runs the window\'s height only for side-by-side screens',
      () {
        const sideways = Size(860, 608);
        expect(
          FoldState.fromFeatures([crease(const Rect.fromLTWH(425, 0, 10, 608))])
              .isVertical(sideways),
          isTrue,
        );
        // A crease across the window (tabletop) is not side by side.
        expect(
          FoldState.fromFeatures([crease(const Rect.fromLTWH(0, 425, 608, 10))])
              .isVertical(const Size(608, 860)),
          isFalse,
        );
        // A zero-width seam (a fold that takes no room) still splits.
        expect(
          FoldState.fromFeatures([crease(const Rect.fromLTWH(430, 0, 0, 608))])
              .isVertical(sideways),
          isTrue,
        );
        // No place at all (all zero) is no fold.
        expect(
          const FoldState(posture: FoldPosture.halfOpened).isVertical(sideways),
          isFalse,
        );
      },
    );
  });

  group('AdaptiveLayout with a fold', () {
    const sideways = Size(860, 608);
    final half = FoldState.fromFeatures([
      crease(const Rect.fromLTWH(425, 0, 10, 608)),
    ]);

    test('without fold information nothing changes', () {
      final a = AdaptiveLayout.forWindow(860, 608);
      final b = AdaptiveLayout.forWindow(860, 608, fold: FoldState.none);
      expect(b.docked, a.docked);
      expect(b.sidebarWidth, a.sidebarWidth);
      expect(b.split, isFalse);
    });

    test('half-folded and sideways: the list has the left screen', () {
      final l = AdaptiveLayout.forWindow(
        sideways.width,
        sideways.height,
        fold: half,
      );
      expect(l.docked, isTrue);
      expect(l.split, isTrue);
      expect(l.sidebarWidth, 435, reason: 'to the crease\'s far edge');
      expect(l.foldGap, 10);
    });

    test('the system\'s left inset moves the crease off the list', () {
      final l = AdaptiveLayout.forWindow(
        sideways.width,
        sideways.height,
        horizontalInsets: 40,
        fold: half,
        leftInset: 40,
      );
      expect(l.sidebarWidth, 395);
    });

    test('flat, or half-folded upright, does not split', () {
      final flat = FoldState(posture: FoldPosture.flat, bounds: half.bounds);
      expect(AdaptiveLayout.forWindow(860, 608, fold: flat).split, isFalse);
      final upright = FoldState.fromFeatures([
        crease(const Rect.fromLTWH(0, 425, 608, 10)),
      ]);
      final l = AdaptiveLayout.forWindow(608, 860, fold: upright);
      expect(l.split, isFalse);
      expect(l.docked, isFalse);
    });

    test('a straight phone is never split, whatever it is told', () {
      final l = AdaptiveLayout.forWindow(
        700,
        360,
        fold: FoldState(
          posture: FoldPosture.halfOpened,
          bounds: const Rect.fromLTWH(345, 0, 10, 360),
        ),
      );
      expect(l.split, isFalse);
    });
  });

  group('the list as a page of its own (inner display held upright)', () {
    test('covers the window upright, on the inner display only', () {
      final inner = AdaptiveLayout.forWindow(608, 860);
      expect(inner.fullPageList, isTrue);
      expect(inner.sidebarWidth, 608);
      expect(inner.docked, isFalse);
      // The outer display and an ordinary phone keep their drawer.
      expect(AdaptiveLayout.forWindow(425, 623).fullPageList, isFalse);
      expect(AdaptiveLayout.forWindow(393, 852).fullPageList, isFalse);
      // Sideways the inner display docks the list instead.
      final side = AdaptiveLayout.forWindow(860, 608);
      expect(side.fullPageList, isFalse);
      expect(side.docked, isTrue);
    });

    test('the whole window, whatever the side insets', () {
      expect(
        AdaptiveLayout.forWindow(608, 860, horizontalInsets: 32).sidebarWidth,
        608,
      );
    });
  });
}
