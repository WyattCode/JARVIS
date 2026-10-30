import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/model/settings.dart';
import 'package:jarvis_android/net/realtime_wire.dart';
import 'package:jarvis_android/voice/voice_session.dart';

import 'voice_support.dart';

/// A socket that can die under the session without announcing it through the stream.
class BrokenWire extends FakeWire {
  bool broken = false, closed = false, eventsThrow = false;
  @override
  Stream<String> get events =>
      eventsThrow ? throw StateError('no stream') : super.events;
  @override
  void send(String value) {
    if (broken) throw StateError('WebSocket is closed');
    super.send(value);
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

class WireApi extends VoiceApi {
  final queue = <BrokenWire>[];
  Completer<void>? gate;
  @override
  Future<RealtimeWire> openRealtime() async {
    await gate?.future;
    final wire = queue.isEmpty ? BrokenWire() : queue.removeAt(0);
    wires.add(wire);
    return wire;
  }
}

class PermissionAudio extends FakeAudio {
  bool granted = false;
  int asked = 0;
  @override
  Future<bool> microphonePermission() async {
    asked++;
    return granted;
  }
}

class Rig {
  Rig({FakeAudio? device}) : audio = device ?? FakeAudio() {
    settings.speechModel = 'speech';
    settings.voices['speech'] = 'Atlas';
    session = VoiceSession(
      api: api,
      audio: audio,
      settings: () => settings,
      catalog: () => [
        ModelInfo(
          'chat',
          'Chat',
          metadata: {
            'jarvis': {
              'voice_effort_models': {'high': 'chat--high'},
            },
          },
        ),
        ModelInfo(
          'speech',
          'Drama 3',
          kind: 'speech',
          defaultVoice: 'Atlas',
          voices: const [VoiceInfo('Atlas', 'Atlas', '')],
        ),
      ],
      effort: () => 'high',
      model: () => 'chat',
      changed: () {},
      onTask: (owner, e) {},
    );
  }
  final api = WireApi(), settings = ChatSettings(), owner = Conversation('o');
  final FakeAudio audio;
  late final VoiceSession session;
  BrokenWire get wire => api.wires.last as BrokenWire;
  void ack() => wire.server.add(
    '{"type":"session.updated","session":{"speech_model":"speech","voice":"Atlas","model":"chat--high","reasoning":true}}',
  );
  Future<void> close() async {
    await session.stop();
    session.dispose();
    await audio.output.close();
    api.close();
  }
}

void main() {
  group('a socket that dies without telling the stream', () {
    test(
      'typed text is not shown as sent and the session reconnects',
      () async {
        final rig = Rig();
        await rig.session.start(rig.owner);
        rig.ack();
        expect(rig.session.ready, isTrue);
        rig.wire.broken = true;
        expect(rig.session.typed('你好'), isFalse);
        expect(rig.owner.messages, isEmpty);
        expect(rig.session.thinking, isFalse);
        await pumpEventQueue();
        expect(rig.session.ready, isFalse);
        expect(rig.session.status, '正在重连');
        await rig.close();
      },
    );

    test('microphone data after the loss does not throw', () async {
      final rig = Rig();
      rig.settings.voiceMode = 'vad';
      await rig.session.start(rig.owner);
      rig.ack();
      rig.wire.broken = true;
      expect(() => rig.audio.input!(Uint8List(960)), returnsNormally);
      await pumpEventQueue();
      expect(rig.session.status, '正在重连');
      await rig.close();
    });
  });

  test('a new call does not inherit the retry count of the last one', () async {
    final rig = Rig();
    await rig.session.start(rig.owner);
    rig.ack();
    await rig.wire.server.close();
    await pumpEventQueue();
    expect(rig.session.status, '正在重连');
    await rig.session.stop();
    rig.api.gate = Completer<void>();
    final restart = rig.session.start(rig.owner);
    await pumpEventQueue();
    expect(rig.session.status, '连接中');
    rig.api.gate!.complete();
    await restart;
    await rig.close();
  });

  test('a failed reconnect closes the socket it had just opened', () {
    fakeAsync((clock) {
      final rig = Rig();
      rig.session.start(rig.owner);
      clock.flushMicrotasks();
      rig.ack();
      final first = rig.wire, bad = BrokenWire()..eventsThrow = true;
      rig.api.queue.add(bad);
      first.server.close();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(bad.closed, isTrue);
      rig.close();
      clock.flushMicrotasks();
    });
  });

  group('microphone permission', () {
    test(
      'a refusal never opens the call page and is exposed to the UI',
      () async {
        final audio = PermissionAudio();
        final rig = Rig(device: audio);
        final seenOpen = <bool>[];
        rig.session.addListener(() => seenOpen.add(rig.session.open));
        await rig.session.start(rig.owner);
        expect(rig.session.permissionDenied, isTrue);
        expect(rig.session.open, isFalse);
        expect(rig.session.active, isFalse);
        expect(seenOpen, isNot(contains(true)));
        expect(rig.session.error, contains('麦克风'));
        expect(audio.starts, 0);
        audio.granted = true;
        await rig.session.start(rig.owner);
        expect(rig.session.permissionDenied, isFalse);
        expect(rig.session.open, isTrue);
        expect(audio.starts, 1);
        await rig.close();
      },
    );

    test(
      'a refusal that only shows up when the device starts is flagged too',
      () async {
        final rig = Rig(device: DeniedAtStart());
        await rig.session.start(rig.owner);
        expect(rig.session.permissionDenied, isTrue);
        expect(rig.session.open, isFalse);
        await rig.close();
      },
    );
  });
}

class DeniedAtStart extends FakeAudio {
  @override
  Future<void> start(
    void Function(Uint8List) input, {
    required bool echoCancel,
  }) async => throw PlatformException(code: 'mic_denied');
}
