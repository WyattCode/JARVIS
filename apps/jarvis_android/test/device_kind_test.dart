import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/adaptive_layout.dart';
import 'package:jarvis_android/model/device_kind.dart';
import 'package:jarvis_android/model/fold_proportions.dart';

/// A folding phone and a straight one are told apart by the system, not by the
/// shape of the window, and each gets the iOS app's rules.
void main() {
  tearDown(DeviceKind.reset);

  FoldColumns columns(double w, double h, {bool docked = false}) =>
      FoldProportions.columns(
        windowWidth: w,
        windowHeight: h,
        paneWidth: w,
        dockedMode: docked,
        sidebarOpen: false,
      );

  group('a folding phone', () {
    setUp(() => DeviceKind.foldable = true);

    test('every window of it is a foldable window, the outer display too', () {
      expect(FoldProportions.isFold(425, 623), isTrue);
      expect(FoldProportions.isFold(623, 425), isTrue);
      expect(FoldProportions.isFold(400, 869), isTrue);
      expect(FoldProportions.isFold(608, 860), isTrue);
    });

    test('outer display upright: a drawer of 88% of the window', () {
      final l = AdaptiveLayout.forWindow(425, 623);
      expect(l.fullPageList, isFalse);
      expect(l.sidebarWidth, closeTo(425 * .88, 1e-9));
    });

    test('outer display sideways: the list covers the window', () {
      final l = AdaptiveLayout.forWindow(623, 425);
      expect(l.fullPageList, isTrue);
      expect(l.sidebarWidth, 623);
    });

    test('inner display: upright a page of its own, sideways docked', () {
      expect(AdaptiveLayout.forWindow(608, 860).fullPageList, isTrue);
      final side = AdaptiveLayout.forWindow(860, 608);
      expect(side.docked, isTrue);
      expect(side.fullPageList, isFalse);
    });

    test('a big drawer stops at 420', () {
      // A window not wide enough to dock (usable width under 760).
      final l = AdaptiveLayout.forWindow(700, 600);
      expect(l.docked, isFalse);
      expect(l.sidebarWidth, 420);
    });
  });

  group('a straight phone', () {
    setUp(() => DeviceKind.foldable = false);

    test('is not a foldable window, whatever its shape', () {
      expect(FoldProportions.isFold(360, 640), isFalse);
      expect(FoldProportions.isFold(411, 731), isFalse);
      expect(FoldProportions.isFold(400, 869), isFalse);
      expect(FoldProportions.isFold(869, 400), isFalse);
      // A large window (a tablet) still is.
      expect(FoldProportions.isFold(800, 1280), isTrue);
    });

    test('held upright the list covers the window', () {
      final l = AdaptiveLayout.forWindow(400, 869);
      expect(l.fullPageList, isTrue);
      expect(l.sidebarWidth, 400);
      expect(l.docked, isFalse);
    });

    test('held sideways the drawer is 80% of the window, at most 420', () {
      final l = AdaptiveLayout.forWindow(869, 400);
      expect(l.fullPageList, isFalse);
      expect(l.docked, isFalse);
      expect(l.sidebarWidth, 420);
      expect(
        AdaptiveLayout.forWindow(500, 360).sidebarWidth,
        closeTo(400, 1e-9),
      );
    });

    test(
      'upright: the box is 16 in from each side, the messages a little less',
      () {
        final c = columns(400, 869);
        expect(c.composer, 368);
        expect(c.messages, 364);
        expect(c.composerInset, 16);
      },
    );

    test('sideways: a reading column of at most 720, centred', () {
      final c = columns(869, 400);
      expect(c.composer, 688);
      expect(c.messages, 684);
      expect(c.composerInset, closeTo((869 - 688) / 2, 1e-9));
    });

    test('a narrow window is the whole of it', () {
      final c = columns(360, 640);
      expect(c.composer, 328);
      expect(c.messages, 324);
    });
  });

  group('with the keyboard up', () {
    FoldColumns up(double w, double h, {bool kb = true, bool docked = false}) =>
        FoldProportions.columns(
          windowWidth: w,
          windowHeight: h,
          paneWidth: w,
          dockedMode: docked,
          sidebarOpen: false,
          keyboardUp: kb,
        );

    test(
      'a foldable\x27s box is wider (17 from each side) and its messages stay',
      () {
        DeviceKind.foldable = true;
        for (final size in [const Size(608, 860), const Size(425, 623)]) {
          final rest = up(size.width, size.height, kb: false);
          final typing = up(size.width, size.height);
          expect(typing.composer, size.width - 17, reason: '$size');
          expect(typing.composer, greaterThan(rest.composer));
          expect(typing.messages, rest.messages, reason: '$size');
        }
      },
    );

    test('a straight phone\x27s box does not change', () {
      DeviceKind.foldable = false;
      expect(up(400, 869).composer, up(400, 869, kb: false).composer);
      expect(up(869, 400).composer, up(869, 400, kb: false).composer);
    });
  });

  group('not known (tests, other platforms)', () {
    test('the window\'s shape is what is guessed from, as it was', () {
      expect(DeviceKind.foldable, isNull);
      expect(FoldProportions.isFold(425, 623), isTrue);
      expect(FoldProportions.isFold(400, 869), isFalse);
      expect(FoldProportions.usesColumns(400, 869), isFalse);
      expect(
        AdaptiveLayout.forWindow(425, 623).sidebarWidth,
        lessThan(425 * .7),
      );
    });
  });
}
