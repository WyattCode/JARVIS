import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/call_wave_glow.dart';
import 'package:jarvis_android/ui/call_mode_toggle.dart';
import 'package:jarvis_android/ui/call_talk_button.dart';
import 'package:jarvis_android/ui/spoken_text_view.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/voice/spoken_text.dart';

import 'support.dart';
import 'voice_support.dart';

/// The call page as the iOS app lays it out.
void main() {
  Future<JarvisController> call() async {
    final c = JarvisController(
      FakeApi(),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await c.initialize();
    c.voice.owner = c.current;
    c.voice.open = true;
    c.voice.ready = true;
    c.voice.status = '已就绪';
    c.voice.hint = '按住按钮开始说话';
    return c;
  }

  Future<void> show(WidgetTester t, JarvisController c, Size size) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size, disableAnimations: true),
          child: VoicePage(controller: c),
        ),
      ),
    );
    await t.pump();
  }

  group('what the page says', () {
    testWidgets('ready, it says what to do: the button, or just speak', (
      t,
    ) async {
      final c = await call();
      await show(t, c, const Size(425, 623));
      expect(find.text('按住按钮说话'), findsOneWidget);
      // Nothing more is said for push-to-talk that is ready.
      expect(find.text('按住按钮开始说话'), findsNothing);
      c.settings.voiceMode = 'vad';
      c.voice.status = '已就绪';
      c.voice.hint = '直接说话即可，停顿后我会回答';
      c.voice.muted = false;
      c.changeSettings((s) => s.voiceMode = 'vad');
      await t.pump();
      expect(find.text('正在聆听'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('a tap holds the voice and says so; the next lets it go', (
      t,
    ) async {
      final c = await call();
      c.voice.speaking = true;
      c.voice.status = '正在说话';
      await show(t, c, const Size(425, 623));
      expect(c.voice.playbackPaused, isFalse);
      // A touch on the page, not on a control.
      await t.tapAt(const Offset(212, 330));
      await t.pump();
      expect(c.voice.playbackPaused, isTrue);
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('再点一下继续'), findsOneWidget);
      await t.tapAt(const Offset(212, 330));
      await t.pump();
      expect(c.voice.playbackPaused, isFalse);
      expect(find.text('已暂停'), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets(
      'a tap on the talk button is not the tap that holds the voice',
      (t) async {
        final c = await call();
        c.voice.speaking = true;
        await show(t, c, const Size(425, 623));
        await t.tap(find.byKey(const Key('voice-talk')));
        await t.pump();
        expect(c.voice.playbackPaused, isFalse);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  });

  group('the controls', () {
    testWidgets('the talk button is one round, label-less button', (t) async {
      final c = await call();
      await show(t, c, const Size(425, 623));
      final r = t.getRect(find.byKey(const Key('voice-hold-surface')));
      expect(r.width, 80);
      expect(r.height, 80);
      // Centred under the words.
      expect(r.center.dx, closeTo(425 / 2, 1));
      expect(find.text('按住说话'), findsNothing);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
      expect(find.byType(ListeningBars), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('hands-free it is sound bars that breathe, not a microphone', (
      t,
    ) async {
      final c = await call();
      c.settings.voiceMode = 'vad';
      await show(t, c, const Size(425, 623));
      expect(find.byType(ListeningBars), findsOneWidget);
      expect(find.byIcon(Icons.mic_rounded), findsNothing);
      final bars = t.widget<ListeningBars>(find.byType(ListeningBars));
      expect(bars.active, isTrue);
      c.voice.muted = true;
      c.voice.status = '已静音';
      await t.pump();
      expect(
        t.widget<ListeningBars>(find.byType(ListeningBars)).active,
        isFalse,
      );
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets(
      'the switch changes the way of talking, and follows the setting',
      (t) async {
        final c = await call();
        await show(t, c, const Size(425, 623));
        expect(c.settings.voiceMode, 'ptt');
        await t.tap(find.byKey(const ValueKey('voice-mode-vad')));
        await t.pump();
        expect(c.settings.voiceMode, 'vad');
        expect(
          t.widget<CallModeToggle>(find.byType(CallModeToggle)).ptt,
          isFalse,
        );
        await t.tap(find.byKey(const ValueKey('voice-mode-ptt')));
        await t.pump();
        expect(c.settings.voiceMode, 'ptt');
        await t.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  });

  group('where the buttons stand', () {
    testWidgets('held upright: a bar along the top, the cross at the corner', (
      t,
    ) async {
      final c = await call();
      await show(t, c, const Size(425, 623));
      final minimize = t.getRect(find.byKey(const Key('voice-minimize')));
      final voice = t.getRect(find.byKey(const Key('voice-name')));
      final mode = t.getRect(find.byType(CallModeToggle));
      final close = t.getRect(find.byKey(const Key('voice-close')));
      expect(minimize.left, lessThan(60));
      expect(minimize.center.dy, lessThan(70));
      expect(voice.center.dy, closeTo(minimize.center.dy, 1));
      // The switch first, then the voice (and works, recovering) joined beside it.
      expect(mode.right, lessThanOrEqualTo(voice.left));
      expect(mode.size, const Size(100, 48));
      expect(mode.right, lessThanOrEqualTo(425));
      expect(close.right, greaterThan(425 - 24));
      expect(close.bottom, greaterThan(623 - 24));
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets(
      'held sideways: a strip at the right edge, the switch stacked',
      (t) async {
        final c = await call();
        await show(t, c, const Size(860, 608));
        final mode = t.getRect(find.byType(CallModeToggle));
        final close = t.getRect(find.byKey(const Key('voice-close')));
        final minimize = t.getRect(find.byKey(const Key('voice-minimize')));
        expect(mode.size, const Size(48, 100));
        for (final r in [mode, close, minimize]) {
          expect(r.left, greaterThan(860 - 70));
          expect(r.right, lessThanOrEqualTo(860));
        }
        expect(minimize.top, lessThan(mode.top));
        expect(close.bottom, greaterThan(608 - 24));
        // The talk button stays centred in what is left of the window.
        final talk = t.getRect(find.byKey(const Key('voice-hold-surface')));
        expect(talk.center.dx, closeTo((860 - 64) / 2, 1));
        await t.pumpWidget(const SizedBox());
        c.dispose();
      },
    );

    testWidgets(
      'recovering and the works appear in the bar when there are any',
      (t) async {
        final c = await call();
        await show(t, c, const Size(425, 623));
        expect(find.byKey(const Key('voice-recover')), findsNothing);
        expect(find.byKey(const Key('voice-works')), findsNothing);
        c.voice.ready = false;
        c.voice.error = '等待恢复语音';
        await t.pump();
        expect(find.byKey(const Key('voice-recover')), findsOneWidget);
        expect(find.text('需要恢复语音'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  });

  group('what you said, and the reply', () {
    testWidgets('what you said is in a pill on the right', (t) async {
      final c = await call();
      c.voice.lastYou = '你好';
      await show(t, c, const Size(425, 623));
      final pill = t.getRect(find.byKey(const Key('voice-you')));
      final column = t.getRect(find.byKey(const Key('voice-transcript')));
      expect(pill.right, closeTo(column.right, 1));
      expect(pill.left, greaterThan(column.left + 40));
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('the light behind the call', () {
    testWidgets('at rest only a faint light at the foot', (t) async {
      final c = await call();
      await show(t, c, const Size(425, 623));
      final glows = t
          .widgetList<CallWaveGlow>(find.byType(CallWaveGlow))
          .toList();
      expect(glows.length, 2);
      final top = glows.firstWhere((g) => g.fromTop);
      final bottom = glows.firstWhere((g) => !g.fromTop);
      expect(top.intensity, 0);
      expect(bottom.intensity, closeTo(.1, 1e-9));
      expect(bottom.level, 0);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('JARVIS speaking: the light comes down from the top', (
      t,
    ) async {
      final c = await call();
      c.voice.speaking = true;
      await show(t, c, const Size(425, 623));
      c.voice.handle({'type': 'noop'});
      final top = t
          .widgetList<CallWaveGlow>(find.byType(CallWaveGlow))
          .firstWhere((g) => g.fromTop);
      expect(top.intensity, greaterThan(.25));
      final bottom = t
          .widgetList<CallWaveGlow>(find.byType(CallWaveGlow))
          .firstWhere((g) => !g.fromTop);
      expect(bottom.intensity, 0);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('JARVIS\'s words lit as they are said', () {
    Future<void> view(
      WidgetTester t,
      SpeechProgress? Function() progress, {
      String text = '你好，世界。这是一句比较长的话。',
      void Function(Rect)? onLine,
    }) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: SpokenTextView(
              text: text,
              size: 16,
              progress: progress,
              onLine: onLine,
              now: () => 0,
            ),
          ),
        ),
      ),
    );

    List<Color?> colours(WidgetTester t) {
      final out = <Color?>[];
      t.widget<RichText>(find.byType(RichText)).text.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          out.add(span.style?.color);
        }
        return true;
      });
      return out;
    }

    testWidgets('without progress the text is plain and bright', (t) async {
      await view(t, () => null);
      final c = colours(t);
      expect(c.toSet().length, 1);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('what is said is bright, what is to come is dim', (t) async {
      var p = const SpeechProgress(
        played: 1.2,
        total: null,
        pace: .19,
        live: true,
        cut: false,
      );
      await view(t, () => p);
      var c = colours(t);
      // The edge is near the start: a bright start, a long dim rest.
      expect(c.last!.a, closeTo(.5, .01));
      final dimTail = c.last!;
      // Further on, more of it is bright and the dim part is shorter.
      p = const SpeechProgress(
        played: 4,
        total: null,
        pace: .19,
        live: true,
        cut: false,
      );
      await view(t, () => p);
      await t.pump(const Duration(milliseconds: 50));
      c = colours(t);
      expect(c.first!.a, 1);
      expect(c.last, dimTail);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('the page is told which line the edge is on', (t) async {
      final lines = <Rect>[];
      const progress = SpeechProgress(
        played: 3,
        total: null,
        pace: .19,
        live: true,
        cut: false,
      );
      await view(t, () => progress, onLine: lines.add);
      await t.pump();
      expect(lines, isNotEmpty);
      expect(lines.first.height, greaterThan(10));
      await t.pumpWidget(const SizedBox());
    });
  });
}
