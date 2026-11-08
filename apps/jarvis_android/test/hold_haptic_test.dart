import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/voice_page.dart';

import 'support.dart';
import 'voice_support.dart';
import 'voice_layout_test.dart' show LayoutApi;

void main() {
  testWidgets(
    'Accepted PTT hold gives one medium haptic, with no repeated or unavailable feedback',
    (t) async {
      final calls = <MethodCall>[];
      var hapticUnavailable = false;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add(call);
            if (hapticUnavailable) throw PlatformException(code: 'unavailable');
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
      final c = JarvisController(
        LayoutApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: VoicePage(controller: c)));
      await t.pump();
      final button = find.byKey(const Key('voice-talk'));
      var finger = await t.startGesture(t.getCenter(button), pointer: 1);
      await t.pump();
      expect(calls, isEmpty);
      await finger.up();
      c.voice.ready = true;
      c.notifyDraftSuggestion();
      await t.pump();
      finger = await t.startGesture(t.getCenter(button), pointer: 2);
      await t.pump();
      expect(c.voice.held, true);
      expect(calls.length, 1);
      expect(calls.single.arguments, 'HapticFeedbackType.mediumImpact');
      final second = await t.startGesture(t.getCenter(button), pointer: 3);
      await t.pump(const Duration(milliseconds: 400));
      expect(calls.length, 1);
      await second.up();
      expect(c.voice.held, true);
      await finger.cancel();
      await t.pump();
      expect(c.voice.held, false);
      expect(calls.length, 1);
      c.voice.previewing = true;
      finger = await t.startGesture(t.getCenter(button), pointer: 4);
      await t.pump();
      expect(calls.length, 1);
      await finger.up();
      c.voice.previewing = false;
      hapticUnavailable = true;
      finger = await t.startGesture(t.getCenter(button), pointer: 5);
      await t.pump();
      expect(c.voice.held, true);
      expect(t.takeException(), isNull);
      await finger.cancel();
      await t.pump();
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
