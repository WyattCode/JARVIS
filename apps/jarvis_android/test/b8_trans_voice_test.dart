import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/login_art.dart' show ReactorMode;
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/voice_page.dart';

import 'c2_support.dart';
import 'support.dart';
import 'voice_support.dart' show FakeAudio;

/// Plain MaterialApp (animations on, unlike `appHost`).
Widget host(Widget child) => MaterialApp(
  home: withLayout(
    DuoLayout.none,
    Scaffold(body: SizedBox.expand(child: child)),
  ),
);

Future<JarvisController> controller(WidgetTester t) async {
  sizeWindow(
    t,
    const Size(402, 874),
    const EdgeInsets.only(top: 62, bottom: 34),
  );
  final c = JarvisController(
    SpeechApi(),
    MemoryVault(),
    audioDevice: FakeAudio(),
  );
  await c.initialize();
  await c.login('user', 'test');
  c.voice.owner = c.current;
  c.voice.ready = true;
  c.voice.status = '已就绪';
  return c;
}

/// The controller saves half a second after a change: let that timer run out.
Future<void> drain(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
}

Offset slide(WidgetTester t) => t
    .widget<SlideTransition>(
      find
          .descendant(
            of: find.byType(VoiceOverlay),
            matching: find.byType(SlideTransition),
          )
          .first,
    )
    .position
    .value;

void main() {
  group('call page enter and exit', () {
    testWidgets('rises from the bottom edge in 320 ms and sinks in 260 ms', (
      t,
    ) async {
      final c = await controller(t);
      Widget app(bool open) => host(VoiceOverlay(controller: c, open: open));
      await t.pumpWidget(app(false));
      expect(find.byType(VoicePage), findsNothing);
      await t.pumpWidget(app(true));
      expect(slide(t), const Offset(0, 1));
      await t.pump(const Duration(milliseconds: 10));
      expect(slide(t).dy, lessThan(1));
      await t.pump(const Duration(milliseconds: 160));
      expect(slide(t).dy, inExclusiveRange(0, .5));
      await t.pump(const Duration(milliseconds: 200));
      expect(slide(t), Offset.zero);

      await t.pumpWidget(app(false));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byType(VoicePage), findsOneWidget);
      expect(slide(t).dy, greaterThan(0));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byType(VoicePage), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion: the page is there at once, no slide', (
      t,
    ) async {
      final c = await controller(t);
      t.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
      Widget app(bool open) => host(VoiceOverlay(controller: c, open: open));
      await t.pumpWidget(app(false));
      await t.pumpWidget(app(true));
      await t.pump();
      expect(slide(t), Offset.zero);
      await t.pumpWidget(app(false));
      await t.pump();
      expect(find.byType(VoicePage), findsNothing);
    });
  });

  group('drag down to minimize', () {
    test('the thresholds', () {
      expect(shouldMinimizeOnDrag(121, 0), isTrue);
      expect(shouldMinimizeOnDrag(120, 0), isFalse);
      expect(shouldMinimizeOnDrag(30, 701), isTrue);
      expect(shouldMinimizeOnDrag(30, 700), isFalse);
    });

    testWidgets('a short pull springs back, a long one minimizes', (t) async {
      final c = await controller(t);
      c.voice.expand();
      await t.pumpWidget(host(VoicePage(controller: c)));
      await t.pump();
      final stage = find.byType(VoiceIdentityStage);
      double offset() => t
          .widget<Transform>(
            find
                .ancestor(
                  of: find.byType(Stack).first,
                  matching: find.byType(Transform),
                )
                .first,
          )
          .transform
          .getTranslation()
          .y;

      final short = await t.startGesture(t.getCenter(stage));
      await short.moveBy(const Offset(0, 40));
      await short.moveBy(const Offset(0, 40));
      await t.pump();
      expect(offset(), greaterThan(30));
      await short.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(c.voice.open, isTrue);
      expect(offset(), 0);

      final far = await t.startGesture(t.getCenter(stage));
      for (var i = 0; i < 4; i++) {
        await far.moveBy(const Offset(0, 50));
      }
      await far.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(c.voice.open, isFalse);
      await drain(t);
    });

    testWidgets('a quick flick minimizes too', (t) async {
      final c = await controller(t);
      c.voice.expand();
      await t.pumpWidget(host(VoicePage(controller: c)));
      await t.pump();
      await t.fling(find.byType(VoiceIdentityStage), const Offset(0, 60), 1500);
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(c.voice.open, isFalse);
      await drain(t);
    });
  });

  group('call controls', () {
    testWidgets('hang up gives a tick first', (t) async {
      final c = await controller(t);
      final haptics = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await t.pumpWidget(host(VoicePage(controller: c)));
      await t.pump();
      await t.tap(find.byTooltip('结束语音通话'));
      await t.pump();
      expect(haptics, contains('HapticFeedbackType.lightImpact'));
      await drain(t);
    });

    testWidgets(
      'muted hands-free state is tinted and the disabled button is .38',
      (t) async {
        final c = await controller(t);
        c.settings.voiceMode = 'vad';
        c.voice.muted = true;
        c.voice.status = '已静音';
        await t.pumpWidget(host(VoicePage(controller: c)));
        await t.pump(const Duration(milliseconds: 400));
        final scheme = Theme.of(t.element(find.byType(VoicePage))).colorScheme;
        final label = t.widget<Text>(
          find.descendant(
            of: find.byKey(const Key('voice-talk')),
            matching: find.text('已静音'),
          ),
        );
        expect(label.style!.color, scheme.error);
        final surface = t.widget<AnimatedContainer>(
          find.byKey(const Key('voice-hold-surface')),
        );
        final border = (surface.decoration! as BoxDecoration).border! as Border;
        expect(border.top.color, scheme.error);
        expect(border.top.width, 2);

        c.voice.ready = false;
        c.voice.muted = false;
        c.voice.status = '连接中';
        c.voice.error = null;
        c.settings.voiceMode = 'ptt';
        c.voice.expand();
        await t.pumpWidget(host(VoicePage(controller: c)));
        await t.pump(const Duration(milliseconds: 400));
        final opacity = t.widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byKey(const Key('voice-hold-surface')),
            matching: find.byType(AnimatedOpacity),
          ),
        );
        expect(opacity.opacity, .38);
        await drain(t);
      },
    );
  });

  group('identity stage status and hint', () {
    Widget stage({required String status, required String hint}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 520,
          child: VoiceIdentityStage(
            compact: true,
            windowHeight: 800,
            identity: 'x',
            status: status,
            hint: hint,
            mode: ReactorMode.idle,
            onTap: () {},
            transcript: const SizedBox(),
          ),
        ),
      ),
    );

    testWidgets('the words cross-fade and the hint does not move sideways', (
      t,
    ) async {
      await t.pumpWidget(stage(status: '正在聆听', hint: '请说话'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      final before = t.getTopLeft(find.text('请说话'));
      await t.pumpWidget(stage(status: '思考中', hint: '请稍候'));
      await t.pump(const Duration(milliseconds: 80));
      expect(find.text('正在聆听'), findsOneWidget, reason: 'fading out');
      expect(find.text('思考中'), findsOneWidget);
      expect(find.text('请说话'), findsOneWidget);
      expect(find.text('请稍候'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('正在聆听'), findsNothing);
      expect(find.text('请说话'), findsNothing);
      expect(t.getTopLeft(find.text('请稍候')).dx, before.dx);
    });
  });
}
