import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/voice/audio_levels.dart';
import 'package:jarvis_android/voice/pcm.dart';
import 'package:jarvis_android/ui/audio_waveform.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/login_art.dart';

import 'voice_support.dart';

void main() {
  test(
    'PCM RMS handles signed samples, silence and incomplete trailing bytes',
    () {
      expect(pcmRms(Uint8List(20)), 0);
      expect(pcmRms(Uint8List.fromList([0, 64, 0, 192])), .5);
      expect(pcmRms(Uint8List.fromList([0, 128])), 1);
      expect(pcmRms(Uint8List.fromList([0])), 0);
    },
  );
  test('Meters follow accepted microphone PCM and hardware playback level, and reset on interruption', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    final pcm = Uint8List.fromList(
      List.generate(960, (i) => i.isEven ? 0 : 64),
    );
    h.audio.input!(pcm);
    expect(h.session.levels.value.input, 0);
    await h.session.hold();
    h.audio.input!(pcm);
    expect(h.session.levels.value.input, .5);
    h.session.cancelHold();
    expect(h.session.levels.value.input, 0);
    h.audio.output.add({'type': 'playback', 'active': true, 'rms': .25});
    expect(h.session.levels.value.output, .25);
    expect(h.session.levels.value.playing, true);
    final changes = h.changes;
    h.audio.output.add({'type': 'playback', 'active': true, 'rms': .6});
    expect(h.session.levels.value.output, .6);
    expect(
      h.changes,
      changes,
      reason: 'Meter updates must not rebuild the full conversation',
    );
    h.audio.output.add({'type': 'playback', 'active': false, 'rms': .9});
    expect(h.session.levels.value.output, 0);
    h.audio.output.add({'type': 'playback', 'active': true, 'rms': .3});
    await h.session.interrupt();
    expect(h.session.levels.value.output, 0);
    expect(h.session.levels.value.playing, false);
    await h.close();
  });
  testWidgets(
    'Wave remains within the compact identity and large text preserves transcript space',
    (t) async {
      final levels = ValueNotifier(const AudioLevels(input: .05));
      for (final size in [
        const Size(400, 869),
        const Size(425, 623),
        const Size(860, 608),
        const Size(623, 425),
      ]) {
        for (final scale in [1.0, 2.5]) {
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = size;
          await t.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: VoiceIdentityStage(
                    compact: true,
                    windowHeight: size.height,
                    identity: 'wave',
                    status: '正在聆听',
                    hint: '按住按钮说话，松开发送',
                    mode: ReactorMode.listening,
                    onTap: () {},
                    waveform: AudioWaveform(levels: levels),
                    transcript: const SizedBox(key: Key('body')),
                  ),
                ),
              ),
            ),
          );
          await t.pump();
          expect(t.takeException(), isNull, reason: '$size / $scale');
          expect(
            t.getSize(find.byKey(const Key('body'))).height,
            greaterThan(60),
          );
          final wave = find.byKey(const Key('voice-waveform'));
          if (wave.evaluate().isNotEmpty) {
            final rect = t.getRect(wave);
            expect(rect.right, lessThanOrEqualTo(size.width));
            expect(
              rect.bottom,
              lessThanOrEqualTo(t.getRect(find.byKey(const Key('body'))).top),
            );
          }
          levels.value = const AudioLevels(playing: true, output: .08);
          await t.pump();
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        }
      }
      levels.dispose();
      t.view.resetDevicePixelRatio();
      t.view.resetPhysicalSize();
    },
  );
}
