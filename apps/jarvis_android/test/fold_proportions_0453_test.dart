import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/fold_proportions.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/audio_waveform.dart';

import 'support.dart';
import 'voice_support.dart';

void main() {
  test('Reference columns cover each posture and both sidebar endpoints', () {
    final fixtures = [
      (425.0, 623.0, 425.0, false, false, 393.0, 347.58885),
      (623.0, 425.0, 623.0, false, false, 518.482588, 487.373633),
      (608.0, 860.0, 608.0, false, false, 437.76, 429.0048),
      (860.0, 608.0, 558.226, true, true, 484.917259, 475.218914),
      (860.0, 608.0, 860.0, true, false, 578.2752, 566.709696),
    ];
    for (final f in fixtures) {
      final c = FoldProportions.columns(
        windowWidth: f.$1,
        windowHeight: f.$2,
        paneWidth: f.$3,
        dockedMode: f.$4,
        sidebarOpen: f.$5,
      );
      expect(c.composer, closeTo(f.$6, .001));
      expect(c.messages, closeTo(f.$7, .001));
      expect(c.messages, lessThan(c.composer));
    }
  });

  testWidgets('Cards and frame align while inner sidebar animates', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(860, 608);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
    await t.pump();
    await t.tap(find.byTooltip('收起会话'));
    await t.pump();
    var previous = t.getRect(find.byKey(const Key('composer-frame'))).width;
    for (var i = 0; i < 15; i++) {
      await t.pump(const Duration(milliseconds: 16));
      final frame = t.getRect(find.byKey(const Key('composer-frame')));
      final pane = t.getRect(find.byType(ChatPanel));
      final left = t.getRect(find.byKey(const ValueKey('starter-0')));
      final right = t.getRect(find.byKey(const ValueKey('starter-1')));
      expect(frame.center.dx, closeTo(pane.center.dx, .1));
      expect(left.left, closeTo(frame.left, .1));
      expect(right.right, closeTo(frame.right, .1));
      expect((frame.width - previous).abs(), lessThan(40));
      previous = frame.width;
    }
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'Fold voice identity, status and wave stay in their transcript column',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      for (final size in [
        const Size(425, 623),
        const Size(623, 425),
        const Size(608, 860),
        const Size(860, 608),
      ]) {
        t.view.physicalSize = size;
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
        c.voice.lastBot = '本地语音比例检查。' * 12;
        await t.pumpWidget(MaterialApp(home: VoicePage(controller: c)));
        await t.pump();
        await t.pump(const Duration(milliseconds: 600));
        final column = t.getRect(find.byKey(const Key('voice-transcript')));
        for (final f in [
          find.byType(CoreAvatar),
          find.text('已就绪'),
          find.byType(AudioWaveform),
        ]) {
          final r = t.getRect(f);
          expect(
            r.left,
            greaterThanOrEqualTo(column.left - .1),
            reason: '$size $f',
          );
          expect(
            r.right,
            lessThanOrEqualTo(column.right + .1),
            reason: '$size $f',
          );
        }
        expect(t.getSize(find.byType(CoreAvatar)).width, closeTo(84, .1));
        expect(find.byType(VoiceIdentityStage), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
  testWidgets(
    'Short outer landscape keyboard keeps input focus, draft and controls reachable',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(623, 425);
      t.view.viewPadding = const FakeViewPadding(top: 46, bottom: 20);
      t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewPadding);
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final input = find.byKey(const Key('chat-input'));
      await t.tap(input);
      await t.enterText(input, '键盘切换时保留草稿');
      final fieldState = t.state(find.byType(EditableText));
      t.view.viewInsets = const FakeViewPadding(bottom: 320);
      t.view.padding = const FakeViewPadding(top: 46);
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      expect(t.state(find.byType(EditableText)), same(fieldState));
      expect(
        t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
        true,
      );
      expect(c.current.draft, '键盘切换时保留草稿');
      final frame = t.getRect(find.byKey(const Key('composer-frame')));
      expect(frame.bottom, lessThanOrEqualTo(425 - 320));
      expect(frame.top, greaterThanOrEqualTo(46));
      expect(find.byTooltip('添加附件').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
