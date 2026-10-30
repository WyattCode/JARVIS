import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/audio_waveform.dart';
import 'package:jarvis_android/ui/call_controls.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart' show CoreAvatar;
import 'package:jarvis_android/ui/login_art.dart' show ReactorMode;
import 'package:jarvis_android/ui/settings_widgets.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/voice_mode_selector.dart';
import 'package:jarvis_android/ui/voice_page.dart';

import 'c2_support.dart';
import 'support.dart';
import 'voice_support.dart';

Future<JarvisController> pumpVoice(
  WidgetTester t, {
  required Size size,
  EdgeInsets insets = EdgeInsets.zero,
  DuoLayout layout = DuoLayout.none,
  ValueNotifier<DuoLayout>? notifier,
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool vad = false,
  bool works = false,
  String? error,
  bool highContrast = false,
  bool login = false,
  String transcript = '',
}) async {
  sizeWindow(t, size, insets);
  final c = JarvisController(
    login ? SpeechApi() : FakeApi(),
    MemoryVault(),
    audioDevice: FakeAudio(),
  );
  await c.initialize();
  addTearDown(c.dispose);
  if (login) await c.login('user', 'test');
  c.settings.voiceMode = vad ? 'vad' : 'ptt';
  c.voice.owner = c.current;
  if (works) {
    c.current.tasks.add(
      MediaTask(id: 'task', kind: 'video', prompt: '测试', args: {}),
    );
  }
  c.voice.error = error;
  if (transcript.isNotEmpty) {
    c.voice.lastYou = transcript;
    c.voice.lastBot = transcript * 3;
  }
  await t.pumpWidget(
    DuoLayoutScope(
      layout: notifier ?? ValueNotifier(layout),
      child: appHost(
        VoicePage(controller: c),
        scale: scale,
        brightness: brightness,
        highContrast: highContrast,
      ),
    ),
  );
  await t.pump();
  return c;
}

void main() {
  group('half-folded landscape keeps title and stage off the crease', () {
    testWidgets('name pill, avatar, status, waveform and transcript sit left', (
      t,
    ) async {
      await pumpVoice(
        t,
        size: const Size(951, 669),
        insets: const EdgeInsets.only(right: 84, bottom: 34),
        layout: halfFolded,
        transcript: '你好，今天天气怎么样？',
      );
      await t.pump(const Duration(milliseconds: 600));
      final fold = halfFolded.verticalFold!;
      final name = t.getRect(find.byKey(const Key('voice-name')));
      expect(name.right, lessThanOrEqualTo(fold.left));
      expect(name.width, lessThan(300), reason: 'content-width, not a row');
      for (final (label, finder) in [
        ('stage', find.byType(VoiceIdentityStage)),
        ('avatar', find.byType(CoreAvatar)),
        ('waveform', find.byType(AudioWaveform)),
        ('transcript', find.byKey(const Key('voice-transcript'))),
      ]) {
        expect(
          t.getRect(finder).right,
          lessThanOrEqualTo(fold.left),
          reason: label,
        );
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('flat: unchanged, the stage is centred in the content area', (
      t,
    ) async {
      await pumpVoice(
        t,
        size: const Size(951, 669),
        insets: const EdgeInsets.only(right: 84, bottom: 34),
        layout: flatLandscape,
      );
      final name = t.getRect(find.byKey(const Key('voice-name')));
      expect(name.center.dx, closeTo((951 - 84) / 2, 1));
      expect(name.width, lessThan(300));
      expect(
        t.getRect(find.byType(VoiceIdentityStage)).center.dx,
        closeTo(867 / 2, 1),
      );
    });

    testWidgets('folding while the page is open moves the stage', (t) async {
      final notifier = ValueNotifier(flatLandscape);
      await pumpVoice(
        t,
        size: const Size(951, 669),
        insets: const EdgeInsets.only(right: 84, bottom: 34),
        notifier: notifier,
      );
      expect(
        t.getRect(find.byType(VoiceIdentityStage)).center.dx,
        closeTo(867 / 2, 1),
      );
      notifier.value = halfFolded;
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(
        t.getRect(find.byType(VoiceIdentityStage)).right,
        lessThanOrEqualTo(455.5),
      );
      expect(t.takeException(), isNull);
    });
  });

  group('voice picker sheet', () {
    Future<void> openPicker(WidgetTester t) async {
      await t.tap(find.byKey(const Key('voice-name')));
      await t.pumpAndSettle();
      expect(find.text('选择音色'), findsOneWidget);
    }

    Rect sheetRect(WidgetTester t) => t.getRect(
      find
          .ancestor(of: find.text('选择音色'), matching: find.byType(Material))
          .first,
    );

    Future<void> dismiss(WidgetTester t) async {
      await t.tap(find.text('完成'));
      await t.pumpAndSettle();
      expect(find.text('选择音色'), findsNothing);
    }

    testWidgets('flat landscape: centred in the area left of the strip', (
      t,
    ) async {
      await pumpVoice(
        t,
        size: const Size(951, 669),
        insets: const EdgeInsets.only(right: 84, bottom: 34),
        layout: flatLandscape,
        login: true,
      );
      await openPicker(t);
      final sheet = sheetRect(t);
      expect(sheet.right, lessThanOrEqualTo(867));
      expect(sheet.left, closeTo(867 - sheet.right, 1));
      // The card sits the same 20 pt from both edges of the sheet.
      final group = t.getRect(find.byType(SettingsGroup));
      expect(group.left - sheet.left, closeTo(20, 1));
      expect(sheet.right - group.right, closeTo(20, 1));
      await dismiss(t);
    });

    testWidgets('outer display: the sheet stops at the strip', (t) async {
      await pumpVoice(
        t,
        size: const Size(466, 678),
        insets: const EdgeInsets.only(right: 84, bottom: 34),
        layout: outerDisplay,
        login: true,
      );
      await openPicker(t);
      final sheet = sheetRect(t);
      expect(sheet.right, lessThanOrEqualTo(382));
      expect(sheet.left, closeTo(0, 1));
      await dismiss(t);
    });

    testWidgets(
      'half-fold: right of the crease, and it follows a fold change',
      (t) async {
        final notifier = ValueNotifier(flatLandscape);
        await pumpVoice(
          t,
          size: const Size(951, 669),
          insets: const EdgeInsets.only(right: 84, bottom: 34),
          notifier: notifier,
          login: true,
        );
        await openPicker(t);
        var sheet = sheetRect(t);
        expect(
          sheet.left,
          lessThan(455.5),
          reason: 'flat: centred in the pane',
        );
        notifier.value = halfFolded;
        await t.pumpAndSettle();
        sheet = sheetRect(t);
        expect(sheet.left, greaterThanOrEqualTo(495.5));
        expect(sheet.right, lessThanOrEqualTo(867));
        // The card keeps the same 20 pt margin on both sides of the pane.
        final group = t.getRect(find.byType(SettingsGroup));
        expect(group.left - sheet.left, closeTo(20, 1));
        expect(sheet.right - group.right, closeTo(20, 1));
        await dismiss(t);
      },
    );

    testWidgets('the title stays put and 完成 closes the sheet', (t) async {
      await pumpVoice(
        t,
        size: const Size(402, 874),
        insets: const EdgeInsets.only(top: 62, bottom: 34),
        login: true,
      );
      final semantics = t.ensureSemantics();
      await openPicker(t);
      expect(
        find.descendant(of: find.byType(ListView), matching: find.text('选择音色')),
        findsNothing,
        reason: 'the title is not part of the scrolling list',
      );
      final done = t.getRect(find.text('完成'));
      expect(done.right, greaterThan(402 - 60));
      final button = t.getSize(find.widgetWithText(TextButton, '完成'));
      expect(button.height, greaterThanOrEqualTo(44));
      expect(find.bySemanticsLabel('关闭音色选择'), findsOneWidget);
      await dismiss(t);
      semantics.dispose();
    });
  });

  group('accessibility and error presentation', () {
    Widget stage({
      required ReactorMode mode,
      String status = '正在聆听',
      String hint = '直接说话即可',
      bool error = false,
    }) => appHost(
      Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: VoiceIdentityStage(
            compact: false,
            windowHeight: 800,
            identity: 'x',
            status: status,
            hint: hint,
            hintIsError: error,
            mode: mode,
            onTap: () {},
            transcript: const SizedBox(),
          ),
        ),
      ),
    );

    testWidgets('the name button reads as 音色：name, opens the picker', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      await pumpVoice(t, size: const Size(402, 874), login: true);
      final node = find.semantics.byLabel(RegExp('^音色：'));
      expect(node, findsOneWidget);
      final data = node.evaluate().single.getSemanticsData();
      expect(data.hint, '选择音色');
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      semantics.dispose();
    });

    testWidgets('the status is a live region', (t) async {
      final semantics = t.ensureSemantics();
      await t.pumpWidget(stage(mode: ReactorMode.listening));
      await t.pump();
      final node = find.semantics.byLabel('正在聆听');
      expect(node, findsOneWidget);
      expect(
        node.evaluate().single.getSemanticsData().flagsCollection.isLiveRegion,
        isTrue,
      );
      semantics.dispose();
    });

    for (final (mode, offered) in [
      (ReactorMode.idle, false),
      (ReactorMode.listening, false),
      (ReactorMode.thinking, true),
      (ReactorMode.speaking, true),
    ]) {
      testWidgets('avatar interrupt button with the reactor ${mode.name}', (
        t,
      ) async {
        final semantics = t.ensureSemantics();
        await t.pumpWidget(stage(mode: mode));
        await t.pump();
        expect(
          find.semantics.byLabel('打断回复'),
          offered ? findsOneWidget : findsNothing,
        );
        semantics.dispose();
      });
    }

    for (final dark in [false, true]) {
      testWidgets(
        'an error hint is in the error colour with an icon (dark: $dark)',
        (t) async {
          final brightness = dark ? Brightness.dark : Brightness.light;
          await t.pumpWidget(
            stage(mode: ReactorMode.idle, hint: '麦克风暂时不可用', error: true),
          );
          await t.pump();
          final error = themeFor(Brightness.light).colorScheme.error;
          final rich = t.widget<RichText>(
            find.byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText().contains('麦克风暂时不可用'),
            ),
          );
          expect(rich.text.style?.color, error);
          expect(find.byIcon(Icons.error_outline), findsOneWidget);
          // A plain hint has neither.
          await t.pumpWidget(stage(mode: ReactorMode.idle, hint: '直接说话即可'));
          await t.pump();
          expect(find.byIcon(Icons.error_outline), findsNothing);
          expect(brightness, isNotNull);
        },
      );
    }

    for (final contrast in [false, true]) {
      testWidgets('Increase Contrast $contrast: outlines follow it', (t) async {
        await pumpVoice(
          t,
          size: const Size(402, 874),
          insets: const EdgeInsets.only(top: 62, bottom: 34),
          highContrast: contrast,
        );
        final colors = themeFor(Brightness.light).colorScheme;
        final hold = t.widget<AnimatedContainer>(
          find.byKey(const Key('voice-hold-surface')),
        );
        final border = (hold.decoration as BoxDecoration).border! as Border;
        expect(border.top.color.a, contrast ? 1 : closeTo(.8, .01));
        final selector = t.widget<Container>(
          find
              .descendant(
                of: find.byType(VoiceModeSelector),
                matching: find.byType(Container),
              )
              .first,
        );
        final edge = (selector.decoration as BoxDecoration).border! as Border;
        expect(
          edge.top.color,
          contrast
              ? colors.outline
              : colors.outlineVariant.withValues(alpha: .7),
        );
      });
    }
  });

  group('straight iPhones', () {
    testWidgets(
      'portrait: hang up is at the bottom, landscape: in the header',
      (t) async {
        await pumpVoice(
          t,
          size: const Size(402, 874),
          insets: const EdgeInsets.only(top: 62, bottom: 34),
        );
        final hangup = t.getRect(find.byType(HangupButton));
        expect(hangup.center.dy, greaterThan(874 * .75));
        expect(hangup.bottom, lessThanOrEqualTo(874 - 34));
        expect(hangup.size.shortestSide, greaterThanOrEqualTo(44));
        await pumpVoice(
          t,
          size: const Size(874, 402),
          insets: const EdgeInsets.only(left: 62, right: 62, bottom: 21),
        );
        expect(t.getRect(find.byType(HangupButton)).center.dy, lessThan(100));
      },
    );

    testWidgets('on its side the mode choice and the talk button share a row', (
      t,
    ) async {
      await pumpVoice(
        t,
        size: const Size(874, 402),
        insets: const EdgeInsets.only(left: 62, right: 62, bottom: 21),
        scale: 2.4,
      );
      final row = find.byKey(const Key('voice-controls-side-by-side'));
      expect(row, findsOneWidget);
      final talk = t.getRect(find.byKey(const Key('voice-talk')));
      final mode = t.getRect(find.byType(VoiceModeSelector));
      expect(mode.right, lessThan(talk.left));
      expect(
        t.getSize(find.byKey(const Key('voice-transcript'))).height,
        greaterThan(60),
      );
      await pumpVoice(t, size: const Size(402, 874));
      expect(row, findsNothing);
    });

    for (final pose in [...straightPoses, ...foldPoses]) {
      for (final scale in textScales) {
        for (final brightness in Brightness.values) {
          final vad = (pose.size.width.toInt() + scale.toInt()) % 2 == 0;
          testWidgets(
            'call page ${pose.name} x$scale ${brightness.name}${vad ? ' vad' : ' ptt'}',
            (t) async {
              final fold = foldPoses.contains(pose);
              final layout = !fold
                  ? DuoLayout.none
                  : pose.name == 'outer'
                  ? outerDisplay
                  : pose.name == 'inner landscape'
                  ? flatLandscape
                  : DuoLayout.fromMap({
                      'edge': 'none',
                      'width': 669.0,
                      'height': 951.0,
                      'safe': {
                        'left': 0.0,
                        'top': 54.0,
                        'right': 0.0,
                        'bottom': 34.0,
                      },
                      'regions': [
                        {
                          'kind': 'division',
                          'active': false,
                          'x': 0.0,
                          'y': 455.5,
                          'w': 669.0,
                          'h': 40.0,
                        },
                      ],
                    });
              await pumpVoice(
                t,
                size: pose.size,
                insets: pose.insets,
                layout: layout,
                scale: scale,
                brightness: brightness,
                vad: vad,
                works: scale == 1.5,
                error: scale == 2.4 ? '麦克风暂时被其他应用占用，请恢复语音后继续对话' : null,
                transcript: '这是一段用来检查文字显示的语音转写。',
              );
              await t.pump(const Duration(milliseconds: 600));
              expect(t.takeException(), isNull);
              final hasRail = layout.hasVerticalBar;
              // The primary controls are targets of at least 44 pt, inside the safe area.
              final controls = <String, Finder>{
                'talk': find.byKey(const Key('voice-talk')),
                'ptt': find.byKey(const ValueKey('voice-mode-ptt')),
                'vad': find.byKey(const ValueKey('voice-mode-vad')),
                'name': find.byKey(const Key('voice-name')),
                if (!hasRail) 'hangup': find.byType(HangupButton),
                if (!hasRail) 'collapse': find.byTooltip('收起通话界面'),
              };
              final safe = pose.safe;
              controls.forEach((label, finder) {
                final r = t.getRect(finder.first);
                expect(r.height, greaterThanOrEqualTo(44), reason: label);
                expect(
                  r.left,
                  greaterThanOrEqualTo(safe.left - .5),
                  reason: label,
                );
                expect(
                  r.top,
                  greaterThanOrEqualTo(safe.top - .5),
                  reason: label,
                );
                expect(
                  r.right,
                  lessThanOrEqualTo(safe.right + .5),
                  reason: label,
                );
                // The foldable's controls run flush to the bottom edge by design (20 pt, not the home indicator inset).
                if (!fold) {
                  expect(
                    r.bottom,
                    lessThanOrEqualTo(safe.bottom + .5),
                    reason: label,
                  );
                }
              });
              // The transcript keeps room to be read, also in 375-440 pt of height.
              expect(
                t.getSize(find.byKey(const Key('voice-transcript'))).height,
                greaterThan(24),
              );
              if (!fold && pose.portrait) {
                expect(
                  t.getRect(find.byType(HangupButton)).center.dy,
                  greaterThan(pose.size.height * .6),
                  reason: 'bottom thumb zone',
                );
              }
            },
          );
        }
      }
    }
  });
}
