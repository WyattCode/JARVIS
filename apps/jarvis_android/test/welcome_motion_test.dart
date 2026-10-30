import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/login_art.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'package:jarvis_android/ui/duo_layout.dart';

import 'duo_rail_test.dart' show pumpHome, duoOuter;
import 'welcome_cards_scale_test.dart' show duoOuterSideways;
import 'support.dart';

void main() {
  testWidgets(
    'Tall phone standby reactor stays high and independent of hint length',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 900);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      Widget screen(String hint) => MaterialApp(
        home: Padding(
          padding: const EdgeInsets.all(20),
          child: VoiceIdentityStage(
            compact: false,
            windowHeight: 900,
            identity: 'stable',
            status: '已就绪',
            hint: hint,
            mode: ReactorMode.idle,
            onTap: () {},
            transcript: const SizedBox(),
          ),
        ),
      );
      await t.pumpWidget(screen('按住说话'));
      final before = t.getRect(find.byType(CoreAvatar));
      expect(before.top, lessThan(100));
      await t.pumpWidget(screen('麦克风暂时不可用，请恢复语音后继续对话。' * 8));
      await t.pump(const Duration(milliseconds: 600));
      expect(t.getRect(find.byType(CoreAvatar)), before);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Voice reactor retains one animation while moving to the transcript corner',
    (t) async {
      final compact = ValueNotifier(false);
      await t.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 600,
            child: ValueListenableBuilder(
              valueListenable: compact,
              builder: (_, value, _) => VoiceIdentityStage(
                compact: value,
                windowHeight: 800,
                identity: 'call',
                status: '正在聆听',
                hint: '按住说话',
                mode: ReactorMode.idle,
                onTap: () {},
                transcript: const Text('对话内容'),
              ),
            ),
          ),
        ),
      );
      final avatar = find.byType(CoreAvatar),
          opening = t.getRect(avatar),
          state = t.state(find.byType(LoginScene));
      compact.value = true;
      await t.pump();
      expect(t.getRect(avatar).width, closeTo(opening.width, .1));
      await t.pump(const Duration(milliseconds: 180));
      final middle = t.getRect(avatar);
      expect(middle.width, lessThan(opening.width));
      expect(middle.width, greaterThan(96));
      await t.pump(const Duration(milliseconds: 320));
      expect(t.getRect(avatar).width, closeTo(96, .1));
      expect(identical(state, t.state(find.byType(LoginScene))), true);
      expect(find.byType(LoginScene), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      compact.dispose();
    },
  );
  testWidgets(
    'Empty chat keeps its welcome composition stationary while only the composer lifts',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 869);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final avatar = find.byType(CoreAvatar),
          start = t.getRect(avatar),
          state = t.state(find.byType(LoginScene));
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await t.pump();
      expect(t.getRect(avatar).width, closeTo(start.width, .1));
      await t.pump(const Duration(milliseconds: 120));
      final middle = t.getRect(avatar).width;
      await t.pump(const Duration(milliseconds: 180));
      final end = t.getRect(avatar).width;
      expect(middle, closeTo(start.width, .1));
      expect(end, closeTo(start.width, .1));
      expect(t.getRect(avatar).top, closeTo(start.top, .1));
      expect(identical(state, t.state(find.byType(LoginScene))), true);
      t.view.viewInsets = FakeViewPadding.zero;
      await t.pump();
      expect(t.getRect(avatar).width, closeTo(end, .1));
      await t.pump(const Duration(milliseconds: 260));
      expect(t.getRect(avatar).width, closeTo(start.width, .1));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Welcome stays in place on outer and inner landscape keyboards; on a short landscape the avatar parks above the composer',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      for (final size in [
        const Size(425, 623),
        const Size(860, 608),
        const Size(623, 425),
      ]) {
        t.view.physicalSize = size;
        t.view.viewInsets = FakeViewPadding.zero;
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
        await t.pump();
        // Let the avatar's resting place be measured.
        await t.pump(const Duration(milliseconds: 50));
        final avatar = find.byType(CoreAvatar), before = t.getRect(avatar);
        t.view.viewInsets = const FakeViewPadding(bottom: 250);
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        final after = t.getRect(avatar);
        if (size.width > size.height && size.height < 520) {
          // A short landscape window: with the keyboard up the avatar sits, smaller, above the composer rather than
          // leaving that room empty.
          final composer = t.getRect(find.byKey(const Key('composer-frame')));
          expect(after.width, lessThan(before.width), reason: '$size');
          expect(
            after.bottom,
            lessThanOrEqualTo(composer.top + 1),
            reason: '$size',
          );
          expect(after.top, greaterThanOrEqualTo(0), reason: '$size');
        } else {
          expect(after.width, closeTo(before.width, .1));
          expect(after.top, closeTo(before.top, .1), reason: '$size');
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );

  testWidgets(
    'On a short landscape the avatar follows the keyboard frame by frame: one steady move up, one back, no jolt',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(678, 466);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      final avatar = find.byType(CoreAvatar);
      // The keyboard as iOS raises it: a new inset every frame along one curve, up and then back down.
      Future<List<Rect>> run(bool up) async {
        final frames = <Rect>[t.getRect(avatar)];
        for (var ms = 16; ms <= 800; ms += 16) {
          final x = (ms / 500).clamp(0.0, 1.0);
          final eased = Curves.easeOutCubic.transform(x);
          t.view.viewInsets = FakeViewPadding(
            bottom: 250 * (up ? eased : 1 - eased),
          );
          await t.pump(const Duration(milliseconds: 16));
          frames.add(t.getRect(avatar));
        }
        return frames;
      }

      final rise = await run(true);
      for (var i = 1; i < rise.length; i++) {
        // Never back the wrong way, never smaller then bigger again, and never further in one frame than the keyboard.
        expect(
          rise[i].center.dy,
          lessThanOrEqualTo(rise[i - 1].center.dy + .01),
        );
        expect(rise[i].width, lessThanOrEqualTo(rise[i - 1].width + .01));
        expect(
          (rise[i].center.dy - rise[i - 1].center.dy).abs(),
          lessThan(24),
          reason: 'frame $i',
        );
      }
      // The keyboard stays up a moment, as it does when someone types.
      await t.pump(const Duration(seconds: 1));
      final fall = await run(false);
      for (var i = 1; i < fall.length; i++) {
        expect(
          fall[i].center.dy,
          greaterThanOrEqualTo(fall[i - 1].center.dy - .01),
        );
        expect(fall[i].width, greaterThanOrEqualTo(fall[i - 1].width - .01));
        expect(
          (fall[i].center.dy - fall[i - 1].center.dy).abs(),
          lessThan(24),
          reason: 'frame $i',
        );
      }
      // Back where it began.
      expect(fall.last.center.dy, closeTo(rise.first.center.dy, 1.5));
      expect(fall.last.width, closeTo(rise.first.width, .5));
    },
  );

  testWidgets(
    'Outer display, upright: tapping the field does not make the avatar jump (the header folds, the page stays put)',
    (t) async {
      await pumpHome(t, duoOuter, size: const Size(466, 678));
      await t.pump(const Duration(milliseconds: 300));
      final avatar = find.byType(CoreAvatar);
      final rest = t.getRect(avatar).center.dy;
      var widest = 0.0;
      for (var ms = 16; ms <= 1200; ms += 16) {
        final eased = Curves.easeOutCubic.transform((ms / 500).clamp(0.0, 1.0));
        t.view.viewInsets = FakeViewPadding(bottom: 300 * eased);
        await t.pump(const Duration(milliseconds: 16));
        widest = math.max(widest, (t.getRect(avatar).center.dy - rest).abs());
      }
      expect(widest, lessThan(1), reason: 'the avatar stays where it is');
      // And back down: no jump either way, and nothing settles once the keyboard has landed (the composer used to slide up
      // a few points after it, taking the page with it).
      final composer = find.byKey(const Key('composer-frame'));
      var step = 0.0, last = t.getRect(avatar).center.dy;
      double? landedAvatar, landedComposer;
      for (var ms = 16; ms <= 1200; ms += 16) {
        final eased = Curves.easeOutCubic.transform((ms / 500).clamp(0.0, 1.0));
        t.view.viewInsets = FakeViewPadding(bottom: 300 * (1 - eased));
        await t.pump(const Duration(milliseconds: 16));
        final now = t.getRect(avatar).center.dy;
        step = math.max(step, (now - last).abs());
        last = now;
        if (landedAvatar == null && t.view.viewInsets.bottom < .01) {
          landedAvatar = now;
          landedComposer = t.getRect(composer).top;
        }
      }
      expect(step, lessThan(6));
      expect(landedAvatar, isNotNull);
      expect(t.getRect(avatar).center.dy, closeTo(landedAvatar!, .3));
      expect(t.getRect(composer).top, closeTo(landedComposer!, .3));
    },
  );

  // The avatar's soft follow lags the keyboard on purpose; it must still never sink behind the composer (it used to reach
  // 15 pt below its top at 844x390 a quarter of a second into the rise), and once it has landed it stops ticking.
  for (final MapEntry(key: name, value: (layout, size, insets)) in {
    '844x390': (
      DuoLayout.none,
      const Size(844, 390),
      const EdgeInsets.only(left: 47, right: 47, bottom: 21),
    ),
    '874x402': (
      DuoLayout.none,
      const Size(874, 402),
      const EdgeInsets.only(left: 62, right: 62, bottom: 21),
    ),
    '678x466': (duoOuterSideways, const Size(678, 466), null),
  }.entries) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Short landscape $name x$scale: the gliding avatar stays above the composer, rising and falling',
        (t) async {
          t.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
          await pumpHome(t, layout, size: size, insets: insets);
          await t.pump(const Duration(milliseconds: 300));
          final avatar = find.byType(CoreAvatar);
          final composer = find.byKey(const Key('composer-frame'));
          final keyboard = size.height < 420 ? 200.0 : 250.0;
          // Tickers running with nothing moving (the reactor's own animation).
          final idle = t.binding.transientCallbackCount;
          for (final up in [true, false]) {
            var landed = 0;
            for (var ms = 16; ms <= 1200; ms += 16) {
              final eased = Curves.easeOutCubic.transform(
                (ms / 500).clamp(0.0, 1.0),
              );
              t.view.viewInsets = FakeViewPadding(
                bottom: keyboard * (up ? eased : 1 - eased),
              );
              await t.pump(const Duration(milliseconds: 16));
              final box = t.getRect(avatar);
              expect(
                box.bottom,
                lessThanOrEqualTo(t.getRect(composer).top),
                reason: '${up ? 'rise' : 'fall'} ${ms}ms',
              );
              expect(box.top, greaterThanOrEqualTo(0));
              if (t.binding.transientCallbackCount > idle) landed = ms;
            }
            // The follow settles (and its ticker stops) well within a second of the keyboard landing at 500 ms.
            expect(landed, lessThan(1100), reason: up ? 'rise' : 'fall');
          }
          expect(t.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('The header fold curve is disposed with the chat page', (
    t,
  ) async {
    final created = <CurvedAnimation>[], disposed = <Object>{};
    void listen(ObjectEvent event) {
      final object = event.object;
      if (event is ObjectCreated && object is CurvedAnimation) {
        created.add(object);
      } else if (event is ObjectDisposed) {
        disposed.add(object);
      }
    }

    FlutterMemoryAllocations.instance.addListener(listen);
    addTearDown(() => FlutterMemoryAllocations.instance.removeListener(listen));
    await pumpHome(
      t,
      DuoLayout.none,
      size: const Size(400, 800),
      insets: EdgeInsets.zero,
    );
    await t.pumpWidget(const SizedBox());
    // The header's: eased out both ways.
    final header = created.where(
      (a) =>
          a.curve == Curves.easeOutCubic &&
          a.reverseCurve is FlippedCurve &&
          (a.reverseCurve! as FlippedCurve).curve == Curves.easeOutCubic,
    );
    expect(header, isNotEmpty);
    for (final curve in header) {
      expect(disposed, contains(curve));
    }
  });
}
