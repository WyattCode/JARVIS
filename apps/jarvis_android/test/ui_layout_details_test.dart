import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/call_mode_toggle.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/media_widgets.dart';
import 'package:jarvis_android/ui/voice_page.dart';

import 'support.dart';
import 'voice_support.dart';

const windows = [
  Size(425, 623),
  Size(623, 425),
  Size(608, 860),
  Size(860, 608),
];

void main() {
  testWidgets('Every call button is reachable with recovery and works shown', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(
      FakeApi(),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await c.initialize();
    c.models.add(
      ModelInfo(
        'speech',
        'Speech',
        kind: 'speech',
        voices: const [VoiceInfo('Mae', 'Mae', '')],
      ),
    );
    c.settings.speechModel = 'speech';
    c.settings.voices['speech'] = 'Mae';
    c.voice.owner = c.current;
    c.voice.error = '等待恢复语音';
    c.current.tasks.add(
      MediaTask(id: 'task', kind: 'video', prompt: '测试', args: {}),
    );
    for (final size in windows) {
      t.view.physicalSize = size;
      await t.pumpWidget(MaterialApp(home: VoicePage(controller: c)));
      await t.pump();
      // The bar (or the side strip, held sideways) carries every button, none
      // outside the window, none covered.
      for (final key in [
        'voice-minimize',
        'voice-recover',
        'voice-works',
        'voice-name',
        'voice-close',
      ]) {
        final finder = find.byKey(Key(key));
        expect(finder.hitTestable(), findsOneWidget, reason: '$size $key');
        final r = t.getRect(finder);
        expect(r.left, greaterThanOrEqualTo(0), reason: '$size $key');
        expect(r.right, lessThanOrEqualTo(size.width), reason: '$size $key');
        expect(r.top, greaterThanOrEqualTo(0), reason: '$size $key');
        expect(r.bottom, lessThanOrEqualTo(size.height), reason: '$size $key');
      }
      expect(find.byType(CallModeToggle).hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
    }
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'Feedback stays above the composer and centered in its pane with IME',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      for (final size in windows) {
        for (final ime in [0.0, 250.0]) {
          t.view.physicalSize = size;
          t.view.viewInsets = FakeViewPadding(bottom: ime);
          await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
          await t.pump();
          final composer = t.getRect(find.byType(Composer));
          showNotice(t.element(find.byKey(const Key('chat-input'))), '审查提示');
          await t.pump();
          await t.pump(const Duration(milliseconds: 300));
          final material = find
              .ancestor(of: find.text('审查提示'), matching: find.byType(Material))
              .first;
          final toast = t.getRect(material);
          expect(
            toast.bottom,
            lessThanOrEqualTo(composer.top - 2),
            reason: '$size/IME $ime',
          );
          expect(toast.center.dx, closeTo(composer.center.dx, .01));
          ScaffoldMessenger.of(t.element(find.byKey(const Key('chat-input'))))
              .removeCurrentSnackBar();
          showNotice(
            t.element(find.byKey(const Key('chat-input'))),
            '会话已删除',
            compact: true,
            action: SnackBarAction(label: '撤销', onPressed: () {}),
          );
          await t.pump();
          await t.pump(const Duration(milliseconds: 300));
          final compactMaterial = find
              .ancestor(of: find.text('会话已删除'), matching: find.byType(Material))
              .first;
          final compactToast = t.getRect(compactMaterial);
          expect(
            compactToast.left,
            closeTo(
              t.getRect(find.byKey(const Key('composer-frame'))).left,
              .1,
            ),
          );
          expect(compactToast.width, lessThan(300));
          expect(compactToast.bottom, lessThanOrEqualTo(composer.top - 2));
          expect(t.getRect(find.text('撤销')).top, lessThan(compactToast.bottom));
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        }
      }
      c.dispose();
    },
  );
}
