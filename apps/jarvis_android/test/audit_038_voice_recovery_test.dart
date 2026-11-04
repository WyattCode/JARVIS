import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_support.dart';

void main() {
  test(
    'Reconnect clears a lost thinking response so a new typed turn can start',
    () {
      fakeAsync((clock) {
        final h = VoiceHarness();
        h.session.start(h.owner);
        clock.flushMicrotasks();
        h.ack();
        h.event({
          'type': 'response.created',
          'response': {'id': 'lost'},
        });
        expect(h.session.thinking, true);
        h.wire.server.close();
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 1));
        clock.flushMicrotasks();
        h.ack();
        expect(h.session.ready, true);
        expect(
          h.session.thinking,
          false,
          reason: 'Transport recovery must not leave a stale generating state',
        );
        expect(h.session.typed('恢复后继续聊天'), true);
        h.close();
        clock.flushMicrotasks();
      });
    },
  );
  test('Stopping while reconnect flush is pending cannot resurrect the reconnect UI', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    h.audio.flushBarrier = Completer<void>();
    unawaited(h.wire.server.close());
    await Future<void>.delayed(Duration.zero);
    await h.session.stop();
    expect(h.session.status, '已结束');
    h.audio.flushBarrier!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(h.session.active, false);
    expect(
      h.session.status,
      '已结束',
      reason: 'An obsolete flush must not publish a new reconnect state',
    );
    h.audio.flushBarrier = null;
    await h.close();
  });
  test('Cancelled response.done with a nested response id cannot finish the next turn', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    h.event({
      'type': 'response.created',
      'response': {'id': 'old'},
    });
    await h.session.interrupt();
    h.event({
      'type': 'response.created',
      'response': {'id': 'new'},
    });
    h.event({
      'type': 'response.done',
      'response': {'id': 'old', 'status': 'cancelled'},
    });
    expect(
      h.session.thinking,
      true,
      reason: 'An old completion cannot clear the new response',
    );
    expect(h.session.typed('不应插入正在生成的回复'), false);
    await h.close();
  });
  test(
    'A failed reconnect audio reset yields an actionable recovery state',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.audio.flushFailure = StateError('simulated output reset failure');
      unawaited(h.wire.server.close());
      await Future<void>.delayed(Duration.zero);
      expect(h.session.ready, false);
      expect(h.session.error, isNotNull);
      h.audio.flushFailure = null;
      await h.close();
    },
  );
  test('A completed PTT turn restores the idle hint instead of asking the user to release', () {
    fakeAsync((clock) {
      final h = VoiceHarness();
      h.session.start(h.owner);
      clock.flushMicrotasks();
      h.ack();
      h.session.hold();
      clock.flushMicrotasks();
      h.event({'type': 'input_audio_buffer.cleared'});
      h.time = h.time.add(const Duration(milliseconds: 400));
      h.session.release();
      clock.elapse(const Duration(milliseconds: 230));
      h.event({'type': 'input_audio_buffer.committed', 'item_id': 'user'});
      h.event({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'user',
        'transcript': '你好',
      });
      h.event({
        'type': 'response.created',
        'response': {'id': 'r'},
      });
      h.event({
        'type': 'response.text.delta',
        'response_id': 'r',
        'item_id': 'bot',
        'delta': '你好，我是贾维斯。',
      });
      h.event({
        'type': 'response.done',
        'response': {'id': 'r', 'status': 'completed'},
      });
      expect(h.session.status, '已就绪');
      expect(h.session.hint, isNot(contains('松开发送')));
      h.close();
      clock.flushMicrotasks();
    });
  });
  test(
    'Hands-free handshake shows instructions for hands-free interaction',
    () {
      fakeAsync((clock) {
        final h = VoiceHarness();
        h.settings.voiceMode = 'vad';
        h.session.start(h.owner);
        clock.flushMicrotasks();
        h.ack();
        expect(h.session.hint, isNot(contains('按住')));
        h.close();
        clock.flushMicrotasks();
      });
    },
  );
}
