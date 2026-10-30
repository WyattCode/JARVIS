import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/net/realtime_wire.dart';
import 'package:jarvis_android/voice/voice_session.dart';

import 'voice_support.dart';

Future<void> tick([int ms = 0]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

List<ModelInfo> catalog() => [
  ModelInfo('chat', 'Chat'),
  ModelInfo(
    'speech',
    'Drama 3',
    kind: 'speech',
    defaultVoice: 'Atlas',
    voices: const [VoiceInfo('Atlas', 'Atlas', '')],
  ),
];

class DeniedApi extends VoiceApi {
  Object? failure;
  int opens = 0;
  @override
  Future<RealtimeWire> openRealtime() {
    opens++;
    if (failure != null) return Future.error(failure!);
    return super.openRealtime();
  }
}

void main() {
  group('mute belongs to hands-free mode', () {
    test('muting in hands-free then switching to push-to-talk shows a normal stage', () async {
      final h = VoiceHarness();
      h.settings.voiceMode = 'vad';
      await h.session.start(h.owner);
      h.ack();
      h.session.toggleMute();
      expect(h.session.status, '已静音');
      expect(h.session.mutedInVad, isTrue);

      h.settings.voiceMode = 'ptt';
      h.session.updateSettings();
      h.ack();
      expect(h.session.muted, isFalse);
      expect(h.session.mutedInVad, isFalse);
      expect(h.session.status, '已就绪');
      expect(h.session.hint, '按住按钮开始说话');
      await h.close();
    });

    test('a new call starts unmuted', () async {
      final h = VoiceHarness();
      h.settings.voiceMode = 'vad';
      await h.session.start(h.owner);
      h.ack();
      h.session.toggleMute();
      await h.session.stop();
      await h.session.start(h.owner);
      expect(h.session.muted, isFalse);
      h.ack();
      expect(h.session.status, '已就绪');
      await h.close();
    });

    test('in push-to-talk a flag left over never reads as muted', () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.session.muted = true;
      h.session.cancelHold();
      expect(h.session.status, '已就绪');
      expect(h.session.mutedInVad, isFalse);
      await h.close();
    });

    test('focus loss in push-to-talk does not turn into a mute', () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.audio.output.add({'type': 'focus_lost'});
      await tick();
      expect(h.session.muted, isFalse);
      expect(await h.session.recover(), isTrue);
      h.ack();
      expect(h.session.status, '已就绪');
      expect(h.session.hint, isNot(contains('点击麦克风')));
      await h.close();
    });

    test('muting while a reply is coming keeps the reply status', () async {
      final h = VoiceHarness();
      h.settings.voiceMode = 'vad';
      await h.session.start(h.owner);
      h.ack();
      h.event({
        'type': 'response.created',
        'response': {'id': 'r1'},
      });
      h.event({'type': 'response.text.delta', 'item_id': 'i1', 'delta': '你好'});
      expect(h.session.status, '正在回复');
      h.session.toggleMute();
      expect(h.session.muted, isTrue);
      expect(h.session.status, '正在回复');
      h.session.toggleMute();
      expect(h.session.status, '正在回复');
      h.event({
        'type': 'response.done',
        'response': {'id': 'r1', 'status': 'completed', 'output': []},
      });
      expect(h.session.status, '已就绪');
      await h.close();
    });
  });

  group('a silent server does not leave the stage waiting forever', () {
    Future<VoiceHarness> committed() async {
      final h = VoiceHarness();
      h.session
        ..turnTimeout = const Duration(milliseconds: 200)
        ..replyTimeout = const Duration(milliseconds: 600);
      await h.session.start(h.owner);
      h.ack();
      await h.session.hold();
      h.event({'type': 'input_audio_buffer.cleared'});
      h.time = h.time.add(const Duration(milliseconds: 600));
      h.session.release();
      await tick(260);
      return h;
    }

    test(
      'no reaction to a committed recording ends in a retryable error',
      () async {
        final h = await committed();
        expect(h.session.status, '正在识别');
        await tick(300);
        expect(h.session.thinking, isFalse);
        expect(h.session.status, '没有收到回复');
        expect(h.session.error, contains('服务器长时间没有回应'));
        expect(
          h.session.ready,
          isTrue,
          reason: 'the user can simply try again',
        );
        await h.close();
      },
    );

    test('any word from the server keeps the wait alive; a started reply waits longer', () async {
      final h = await committed();
      h.event({'type': 'input_audio_buffer.committed', 'item_id': 'u1'});
      await tick(50);
      h.event({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'u1',
        'transcript': '你好',
      });
      h.event({
        'type': 'response.created',
        'response': {'id': 'r1'},
      });
      await tick(350);
      expect(h.session.error, isNull, reason: 'reasoning may take a while');
      expect(h.session.status, '正在思考');
      await tick(500);
      expect(h.session.error, contains('服务器长时间没有回应'));
      await h.close();
    });

    test('a finished reply cancels the timer', () async {
      final h = await committed();
      h.event({'type': 'input_audio_buffer.committed', 'item_id': 'u1'});
      h.event({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'u1',
        'transcript': '你好',
      });
      h.event({
        'type': 'response.created',
        'response': {'id': 'r1'},
      });
      h.event({
        'type': 'response.done',
        'response': {'id': 'r1', 'status': 'completed', 'output': []},
      });
      await tick(750);
      expect(h.session.error, isNull);
      expect(h.session.status, '已就绪');
      await h.close();
    });

    test('a typed message that never gets an answer times out too', () async {
      final h = VoiceHarness();
      h.session.turnTimeout = const Duration(milliseconds: 80);
      await h.session.start(h.owner);
      h.ack();
      expect(h.session.typed('在吗'), isTrue);
      expect(h.session.status, '正在思考');
      await tick(150);
      expect(h.session.thinking, isFalse);
      expect(h.session.error, isNotNull);
      await h.close();
    });
  });

  group('a preview failure is not the call error', () {
    test(
      'it lands in previewError and the next attempt or stop clears it',
      () async {
        final h = VoiceHarness();
        final failed = h.session.playPreview(
          const VoiceInfo('Mae', 'Mae', ''),
          'speech',
        );
        await tick();
        h.api.previews['Mae']!.completeError(StateError('offline'));
        await failed;
        expect(h.session.previewError, contains('试听'));
        expect(h.session.error, isNull);
        expect(h.session.hint, isEmpty);

        final retry = h.session.playPreview(
          const VoiceInfo('Atlas', 'Atlas', ''),
          'speech',
        );
        await tick();
        expect(h.session.previewError, isNull);
        h.api.previews['Atlas']!.completeError(StateError('offline'));
        await retry;
        expect(h.session.previewError, isNotNull);
        await h.session.stopPreview();
        expect(h.session.previewError, isNull);
        await h.close();
      },
    );

    test('a live call keeps its own error while a preview fails', () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.event({
        'type': 'error',
        'error': {'code': 'x'},
      });
      final callError = h.session.error;
      expect(callError, isNotNull);
      final failed = h.session.playPreview(
        const VoiceInfo('Mae', 'Mae', ''),
        'speech',
      );
      await tick();
      h.api.previews['Mae']!.completeError(StateError('offline'));
      await failed;
      expect(h.session.previewError, isNotNull);
      expect(h.session.error, callError);
      await h.close();
    });
  });

  group('recover keeps the call page open', () {
    test('success: open never drops, the call is up again', () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      final opens = <bool>[];
      h.session.addListener(() => opens.add(h.session.open));
      expect(await h.session.recover(), isTrue);
      expect(opens, isNotEmpty);
      expect(opens, everyElement(isTrue));
      expect(h.session.active, isTrue);
      expect(h.api.wires, hasLength(2));
      await h.close();
    });

    test(
      'failure: the page stays, with the reason and the way to retry',
      () async {
        final h = VoiceHarness();
        await h.session.start(h.owner);
        h.ack();
        h.settings.voices['speech'] = 'Gone';
        final opens = <bool>[];
        h.session.addListener(() => opens.add(h.session.open));
        expect(await h.session.recover(), isFalse);
        expect(opens, everyElement(isTrue));
        expect(h.session.open, isTrue);
        expect(h.session.active, isFalse);
        expect(h.session.error, contains('音色不可用'));
        expect(h.session.needsRecovery, isTrue);
        // The plain stop-then-start the old UI used loses the page on the same failure.
        await h.session.stop();
        await h.session.start(h.owner);
        expect(h.session.open, isFalse);
        await h.close();
      },
    );

    test('a refused microphone is reported on the open page', () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      // FakeAudio always grants; deny through a subclass-free route: the permission result is read from the device.
      final denied = _DeniedAudio();
      final session = VoiceSession(
        api: h.api,
        audio: denied,
        settings: () => h.settings,
        catalog: catalog,
        effort: () => 'high',
        model: () => 'chat',
        changed: () {},
        onTask: (_, _) {},
      );
      session.owner = h.owner;
      expect(await session.recover(), isFalse);
      session.dispose();
      await h.close();
    });

    test('hanging up while it restarts wins', () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.audio.stopBarrier = Completer<void>();
      final recovering = h.session.recover();
      await tick();
      final hangup = h.session.stop();
      h.audio.stopBarrier!.complete();
      await hangup;
      expect(await recovering, isFalse);
      expect(h.session.active, isFalse);
      expect(h.session.open, isFalse);
      await h.close();
    });
  });

  group('an unauthorized handshake expires the session', () {
    VoiceSession build(
      DeniedApi api,
      VoiceHarness h,
      void Function() onExpired,
    ) => VoiceSession(
      api: api,
      audio: h.audio,
      settings: () => h.settings,
      catalog: catalog,
      effort: () => 'high',
      model: () => 'chat',
      changed: () {},
      onTask: (_, _) {},
      onUnauthorized: onExpired,
    );

    test(
      'at start: the login-expired message, no mic problem, owner told',
      () async {
        final h = VoiceHarness();
        final api = DeniedApi()
          ..failure = const JarvisException('登录已过期，请重新登录', unauthorized: true);
        var expired = 0;
        final session = build(api, h, () => expired++);
        await session.start(h.owner);
        expect(session.error, contains('登录已过期'));
        expect(session.permissionDenied, isFalse);
        expect(expired, 1);
        expect(session.active, isFalse);
        session.dispose();
        await h.audio.output.close();
      },
    );

    test(
      'while reconnecting: stops at once instead of retrying eight times',
      () async {
        final h = VoiceHarness();
        final api = DeniedApi();
        var expired = 0;
        final session = build(api, h, () => expired++);
        await session.start(h.owner);
        expect(api.opens, 1);
        api.failure = const JarvisException('登录已过期，请重新登录', unauthorized: true);
        await api.wires.last.server.close();
        await tick(1300);
        expect(api.opens, 2);
        expect(expired, 1);
        expect(session.error, contains('登录已过期'));
        expect(session.active, isFalse);
        session.dispose();
        await h.audio.output.close();
      },
    );
  });
}

class _DeniedAudio extends FakeAudio {
  @override
  Future<bool> microphonePermission() async => false;
}
