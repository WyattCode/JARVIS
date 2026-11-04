import 'dart:async';
import 'dart:typed_data';

import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/model/settings.dart';
import 'package:jarvis_android/net/realtime_wire.dart';
import 'package:jarvis_android/voice/audio_device.dart';
import 'package:jarvis_android/voice/pcm.dart';
import 'package:jarvis_android/voice/voice_session.dart';

import 'support.dart';

import 'dart:convert';

class FakeWire implements RealtimeWire {
  final server = StreamController<String>.broadcast(sync: true);
  final sent = <Map<String, dynamic>>[];
  @override
  Stream<String> get events => server.stream;
  @override
  void send(String value) =>
      sent.add(Map<String, dynamic>.from(jsonDecode(value) as Map));
  @override
  Future<void> close() async {
    if (!server.isClosed) await server.close();
  }
}

class VoiceApi extends FakeApi {
  final wires = <FakeWire>[];
  final previews = <String, Completer<Uint8List>>{};
  @override
  Future<RealtimeWire> openRealtime() async {
    final wire = FakeWire();
    wires.add(wire);
    return wire;
  }

  @override
  Future<Uint8List> preview(VoiceInfo voice, String model) =>
      previews.putIfAbsent(voice.id, () => Completer<Uint8List>()).future;
}

/// A server-backed catalog for controller tests that start a voice call.
class CatalogVoiceApi extends VoiceApi {
  @override
  Future<List<ModelInfo>> models() async => [
    ...await super.models(),
    ModelInfo('speech', 'Speech', kind: 'speech', defaultVoice: 'Atlas',
      voices: const [VoiceInfo('Atlas', 'Atlas', '')]),
  ];
}

class FakeAudio extends AudioDevice {
  final output = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final fed = <Uint8List>[], clips = <PcmClip>[];
  void Function(Uint8List)? input;
  int starts = 0, stops = 0, flushes = 0, finishes = 0, reconfigures = 0;
  bool? echo;
  Completer<void>? stopBarrier, flushBarrier;
  Object? flushFailure;
  @override
  Future<void> reconfigureInput(
    void Function(Uint8List) input, {
    required bool echoCancel,
  }) async {
    this.input = input;
    echo = echoCancel;
    reconfigures++;
  }

  @override
  Stream<Map<String, dynamic>> get events => output.stream;
  @override
  Future<void> start(
    void Function(Uint8List) input, {
    required bool echoCancel,
  }) async {
    this.input = input;
    starts++;
  }

  @override
  Future<void> feed(Uint8List bytes) async {
    fed.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> finish() async {
    finishes++;
  }

  @override
  Future<void> flush() async {
    flushes++;
    if (flushFailure != null) throw flushFailure!;
    fed.clear();
    await flushBarrier?.future;
  }

  @override
  Future<void> preview(PcmClip clip) async {
    clips.add(clip);
  }

  @override
  Future<void> stop() async {
    stops++;
    input = null;
    await stopBarrier?.future;
  }
}

class VoiceHarness {
  final api = VoiceApi(),
      audio = FakeAudio(),
      settings = ChatSettings(),
      owner = Conversation('voice-owner');
  DateTime time = DateTime(2026, 10, 25);
  String effort = 'high';
  int changes = 0;
  final jobs = <Map<String, dynamic>>[];
  late final VoiceSession session;
  VoiceHarness() {
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
          voices: const [
            VoiceInfo('Atlas', 'Atlas', ''),
            VoiceInfo('Mae', 'Mae', ''),
          ],
        ),
      ],
      effort: () => effort,
      model: () => 'chat',
      changed: () {
        changes++;
      },
      onTask: (owner, e) => jobs.add(e),
      now: () => time,
    );
  }
  FakeWire get wire => api.wires.last;
  void event(Map<String, dynamic> event) => wire.server.add(jsonEncode(event));
  void ack({
    String voice = 'Atlas',
    String model = 'chat--high',
    bool reasoning = true,
  }) => event({
    'type': 'session.updated',
    'session': {
      'speech_model': 'speech',
      'voice': voice,
      'model': model,
      'reasoning': reasoning,
    },
  });
  Future<void> close() async {
    await session.stop();
    session.dispose();
    await audio.output.close();
    api.close();
  }
}

Uint8List wavBytes({
  int rate = 24000,
  int channels = 1,
  int bits = 16,
  int count = 240,
}) {
  final b = Uint8List(44 + count * 2), v = ByteData.sublistView(b);
  void tag(int at, String value) {
    b.setRange(at, at + value.length, value.codeUnits);
  }

  tag(0, 'RIFF');
  v.setUint32(4, b.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  v.setUint32(16, 16, Endian.little);
  v.setUint16(20, 1, Endian.little);
  v.setUint16(22, channels, Endian.little);
  v.setUint32(24, rate, Endian.little);
  v.setUint32(28, rate * 2, Endian.little);
  v.setUint16(32, 2, Endian.little);
  v.setUint16(34, bits, Endian.little);
  tag(36, 'data');
  v.setUint32(40, count * 2, Endian.little);
  return b;
}
