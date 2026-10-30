import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/voice_mode_selector.dart';
import 'package:jarvis_android/ui/voice_page.dart';

import 'c2_support.dart';
import 'c3_support.dart';
import 'support.dart';
import 'voice_support.dart' show FakeAudio;

Future<JarvisController> pumpVoice3(
  WidgetTester t, {
  Size size = const Size(402, 874),
  EdgeInsets insets = const EdgeInsets.only(top: 62, bottom: 34),
  bool vad = false,
  bool ready = true,
  bool muted = false,
  String? error,
  FakeAudio? audio,
}) async {
  sizeWindow(t, size, insets);
  final c = JarvisController(
    SpeechApi(),
    MemoryVault(),
    audioDevice: audio ?? FakeAudio(),
  );
  await c.initialize();
  await c.login('user', 'test');
  c.settings.voiceMode = vad ? 'vad' : 'ptt';
  c.voice.owner = c.current;
  c.voice.ready = ready;
  c.voice.muted = muted;
  c.voice.error = error;
  c.voice.status = muted ? '已静音' : '已就绪';
  await t.pumpWidget(
    withLayout(
      DuoLayout.none,
      appHost(
        Scaffold(
          body: SizedBox.expand(child: VoicePage(controller: c)),
        ),
      ),
    ),
  );
  await t.pump();
  return c;
}

void main() {
  group('a failed recovery tells the user', () {
    testWidgets('permission revoked: the notice offers Settings', (t) async {
      final c = await pumpVoice3(
        t,
        ready: false,
        error: '麦克风暂时不可用',
        audio: DeniedAudio(),
      );
      await t.tap(find.text('恢复语音'));
      await t.pump();
      // start() waits on root-zone futures (permission check, stream cancel): let the real event loop turn.
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('需要麦克风权限'),
        ),
        findsOneWidget,
      );
      expect(find.text('去设置'), findsOneWidget);
      expect(c.voice.active, isFalse);
      await end(t, c);
    });
  });

  group('mute state', () {
    testWidgets('push-to-talk ignores a mute left from hands-free', (t) async {
      final c = await pumpVoice3(t, muted: true);
      expect(find.byIcon(Icons.mic_off_outlined), findsNothing);
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      // Button: the action. Stage: the session status without the stale mute.
      expect(
        find.descendant(
          of: find.byKey(const Key('voice-talk')),
          matching: find.text('按住说话'),
        ),
        findsOneWidget,
      );
      expect(find.text('已静音'), findsNothing);
      expect(find.text('已就绪'), findsOneWidget);
      await end(t, c);
    });

    testWidgets('hands-free shows the mute', (t) async {
      final c = await pumpVoice3(t, vad: true, muted: true);
      expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
      expect(find.text('已静音'), findsWidgets);
      await end(t, c);
    });

    testWidgets('hands-free ready: stage and button use one word', (t) async {
      final c = await pumpVoice3(t, vad: true);
      expect(find.text('正在聆听'), findsNWidgets(2));
      expect(find.text('已就绪'), findsNothing);
      await end(t, c);
    });

    testWidgets('the talk surface ripples above its own fill', (t) async {
      final c = await pumpVoice3(t, vad: true);
      final surface = find.byKey(const Key('voice-hold-surface'));
      final ink = find.descendant(of: surface, matching: find.byType(InkWell));
      expect(ink, findsOneWidget);
      // The nearest Material of the ripple sits inside the decorated surface, not above it.
      final material = find
          .ancestor(of: ink, matching: find.byType(Material))
          .first;
      expect(find.descendant(of: surface, matching: material), findsOneWidget);
      await end(t, c);
    });
  });

  group('haptics', () {
    testWidgets('mode switch and hands-free mute tap click', (t) async {
      final haptics = recordHaptics(t);
      final c = await pumpVoice3(t, vad: true);
      await t.tap(find.byKey(const ValueKey('voice-mode-ptt')));
      await t.pump();
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      haptics.clear();
      // Selecting what is already selected is silent.
      await t.tap(find.byKey(const ValueKey('voice-mode-ptt')));
      await t.pump();
      expect(haptics, isEmpty);
      c.settings.voiceMode = 'vad';
      c.notifyDraftSuggestion();
      await t.pump();
      await t.tap(find.byKey(const Key('voice-hold-surface')));
      await t.pump();
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      expect(c.voice.muted, isTrue);
      await end(t, c);
    });

    testWidgets('releasing the talk button clicks once', (t) async {
      final haptics = recordHaptics(t);
      final c = await pumpVoice3(t);
      final finger = await t.startGesture(
        t.getCenter(find.byKey(const Key('voice-talk'))),
      );
      await t.pump();
      haptics.clear();
      await finger.up();
      await t.pump();
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      await end(t, c);
    });

    testWidgets('mode selector alone: 44 pt targets on a narrow phone', (
      t,
    ) async {
      sizeWindow(t, const Size(375, 667), const EdgeInsets.only(top: 20));
      await t.pumpWidget(
        appHost(
          Scaffold(
            body: VoiceModeSelector(value: 'ptt', onChanged: (_) {}),
          ),
          scale: 2.4,
        ),
      );
      for (final id in ['ptt', 'vad']) {
        expect(
          t.getSize(find.byKey(ValueKey('voice-mode-$id'))).height,
          greaterThanOrEqualTo(44),
        );
      }
      expect(t.takeException(), isNull);
    });
  });
}
