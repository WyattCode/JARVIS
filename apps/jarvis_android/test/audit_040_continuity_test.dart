import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/voice_page.dart';

import 'voice_layout_test.dart' show LayoutApi, settleTask;
import 'voice_support.dart';
import 'support.dart';

void ack(JarvisController c) => c.voice.handle({
  'type': 'session.updated',
  'session': {
    'speech_model': 'speech',
    'voice': 'Atlas',
    'model': 'chat--high',
    'reasoning': true,
  },
});
Future<JarvisController> prepared() async {
  final c = JarvisController(
    LayoutApi(),
    MemoryVault(),
    audioDevice: FakeAudio(),
  );
  await c.initialize();
  await c.login('Audit', 'test');
  await c.voice.start(c.current);
  ack(c);
  return c;
}

void main() {
  test(
    'Configuration acknowledgement preserves thinking and reply status',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.event({
        'type': 'response.created',
        'response': {'id': 'r'},
      });
      h.session.updateSettings();
      h.ack();
      final thinkingStatus = h.session.status;
      h.event({
        'type': 'response.text.delta',
        'response_id': 'r',
        'item_id': 'b',
        'delta': '你好',
      });
      h.session.updateSettings();
      h.ack();
      final replyingStatus = h.session.status;
      await h.close();
      expect(thinkingStatus, '正在思考');
      expect(replyingStatus, '正在回复');
    },
  );
  test(
    'Configuration acknowledgement preserves playback and muted status',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.audio.output.add({'type': 'playback', 'active': true, 'rms': .1});
      h.session.updateSettings();
      h.ack();
      final playing = h.session.status;
      h.audio.output.add({'type': 'playback', 'active': false});
      h.session.toggleMute();
      h.session.updateSettings();
      h.ack();
      final muted = h.session.status;
      await h.close();
      expect(playing, '正在说话');
      expect(muted, '已静音');
    },
  );
  test('Changing message font does not clear microphone input or renegotiate the voice session', () async {
    final c = await prepared();
    final api = c.api as LayoutApi;
    final wire = api.wires.last;
    final sent = wire.sent.length;
    c.changeSettings((s) => s.messageFontSize = 20);
    c.setEffort(c.effort);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final events = wire.sent.skip(sent).map((e) => e['type']).toList();
    final ready = c.voice.ready;
    await c.voice.stop();
    c.dispose();
    expect(events, isNot(contains('input_audio_buffer.clear')));
    expect(events, isNot(contains('session.update')));
    expect(ready, true);
  });
  testWidgets(
    'A modal covering PTT cancels the hold instead of leaving a hidden recording',
    (t) async {
      late JarvisController c;
      await t.runAsync(() async {
        c = await prepared();
      });
      await t.pumpWidget(MaterialApp(home: VoicePage(controller: c)));
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.space);
      await t.pump();
      expect(c.voice.held, true);
      final nav = Navigator.of(t.element(find.byType(VoicePage)));
      nav.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('modal fixture')),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      final hiddenRecording = c.voice.held;
      await t.sendKeyUpEvent(LogicalKeyboardKey.space);
      await t.pumpWidget(const SizedBox());
      await settleTask(t, c.voice.stop());
      c.dispose();
      expect(hiddenRecording, false);
    },
  );
  testWidgets(
    'Losing app focus cancels PTT and does not commit a hidden utterance',
    (t) async {
      late JarvisController c;
      await t.runAsync(() async {
        c = await prepared();
      });
      await t.pumpWidget(MaterialApp(home: VoicePage(controller: c)));
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.space);
      await t.pump();
      expect(c.voice.held, true);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await t.pump();
      final held = c.voice.held;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.sendKeyUpEvent(LogicalKeyboardKey.space);
      await t.pumpWidget(const SizedBox());
      await settleTask(t, c.voice.stop());
      c.dispose();
      expect(held, false);
    },
  );
  test('A playback drain cannot replace an active recognition retry hint with idle', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    h.settings.voiceMode = 'vad';
    h.audio.output.add({'type': 'playback', 'active': true, 'rms': .1});
    h.event({'type': 'input_audio_buffer.committed', 'item_id': 'bad'});
    h.event({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'bad',
      'transcript': '',
    });
    h.audio.output.add({'type': 'playback', 'active': false});
    final status = h.session.status;
    await h.close();
    expect(status, '没有听清');
  });
}
