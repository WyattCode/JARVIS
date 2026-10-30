import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'support.dart';
import 'voice_support.dart';

Future<void> tick() => Future<void>.delayed(Duration.zero);

/// Serves the harness catalog (a chat model and a speech model with two voices) so the controller can start a call.
class CatalogApi extends VoiceApi {
  @override
  Future<List<ModelInfo>> models() async => [
    ModelInfo('chat', 'Chat'),
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
  ];
}

const mae = VoiceInfo('Mae', 'Mae', '');
const atlas = VoiceInfo('Atlas', 'Atlas', '');

void main() {
  group('preview error', () {
    test('a failed preview leaves no stale error for the next one', () async {
      final h = VoiceHarness();
      final failed = h.session.playPreview(mae, 'speech');
      await tick();
      h.api.previews['Mae']!.completeError(StateError('offline'));
      await failed;
      // A failed preview belongs to the picker, not to the call: it never shows up as the call's error.
      expect(h.session.previewError, contains('试听'));
      expect(h.session.error, isNull);
      final retry = h.session.playPreview(atlas, 'speech');
      await tick();
      expect(
        h.session.previewError,
        isNull,
        reason: 'cleared when the new one starts',
      );
      h.api.previews['Atlas']!.complete(wavBytes());
      await retry;
      expect(h.session.previewError, isNull);
      await h.close();
    });

    test('a live call keeps its own error through a preview', () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.audio.output.add({'type': 'focus_lost'});
      await tick();
      final live = h.session.error;
      expect(live, isNotNull);
      final preview = h.session.playPreview(mae, 'speech');
      await tick();
      expect(h.session.error, live);
      h.api.previews['Mae']!.complete(wavBytes());
      await preview;
      await h.close();
    });
  });

  group('previewLoading', () {
    test('true from the tap until the first audio is queued', () async {
      final h = VoiceHarness();
      var notified = 0;
      h.session.addListener(() => notified++);
      expect(h.session.previewLoading, isFalse);
      final preview = h.session.playPreview(mae, 'speech');
      expect(
        h.session.previewLoading,
        isTrue,
        reason: 'at the tap, synchronously',
      );
      expect(notified, greaterThan(0));
      await tick();
      expect(h.session.previewing, isTrue);
      expect(h.session.previewLoading, isTrue, reason: 'still downloading');
      expect(h.audio.clips, isEmpty);
      h.api.previews['Mae']!.complete(wavBytes());
      await preview;
      expect(h.audio.clips, hasLength(1));
      expect(h.session.previewLoading, isFalse);
      expect(h.session.previewing, isTrue);
      await h.close();
    });

    test('a failed download ends the loading state', () async {
      final h = VoiceHarness();
      final preview = h.session.playPreview(mae, 'speech');
      await tick();
      h.api.previews['Mae']!.completeError(StateError('offline'));
      await preview;
      expect(h.session.previewLoading, isFalse);
      expect(h.session.previewing, isFalse);
      await h.close();
    });

    test('a stop nobody waits for cannot raise an unhandled error', () async {
      final h = VoiceHarness();
      h.audio.flushFailure = StateError('flush failed');
      unawaited(h.session.stopPreview());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Whoever does wait still hears about it.
      await expectLater(h.session.stopPreview(), throwsStateError);
      h.audio.flushFailure = null;
      await h.close();
    });

    test('stopping while it downloads ends the loading state', () async {
      final h = VoiceHarness();
      final preview = h.session.playPreview(mae, 'speech');
      await tick();
      await h.session.stopPreview();
      expect(h.session.previewLoading, isFalse);
      h.api.previews['Mae']!.complete(wavBytes());
      await preview;
      expect(h.session.previewLoading, isFalse);
      expect(h.audio.clips, isEmpty, reason: 'a stopped preview never plays');
      await h.close();
    });

    test(
      'a newer preview owns the flag when an older one is superseded',
      () async {
        final h = VoiceHarness();
        final a = h.session.playPreview(atlas, 'speech');
        await tick();
        final b = h.session.playPreview(mae, 'speech');
        await tick();
        h.api.previews['Atlas']!.complete(wavBytes());
        await a;
        expect(
          h.session.previewLoading,
          isTrue,
          reason: 'Mae is still loading',
        );
        h.api.previews['Mae']!.complete(wavBytes());
        await b;
        expect(h.session.previewLoading, isFalse);
        await h.close();
      },
    );

    test('an audio device failure ends it too', () async {
      final h = VoiceHarness();
      final preview = h.session.playPreview(mae, 'speech');
      await tick();
      h.audio.output.add({'type': 'output_error'});
      await tick();
      expect(h.session.previewLoading, isFalse);
      h.api.previews['Mae']!.complete(wavBytes());
      await preview;
      expect(h.session.previewLoading, isFalse);
      await h.close();
    });
  });

  group('changing the voice in the settings', () {
    Future<(JarvisController, FakeAudio, CatalogApi)> make() async {
      final audio = FakeAudio();
      final a = CatalogApi()..cookie = '__Host-jarvis_session=test';
      final c = JarvisController(a, MemoryVault(), audioDevice: audio);
      await c.initialize();
      return (c, audio, a);
    }

    test('drops the error left by the old engine or voice', () async {
      final (c, audio, a) = await make();
      c.changeSettings((s) {
        s.speechModel = 'speech';
        s.voices['speech'] = 'Atlas';
      });
      final failed = c.voice.playPreview(mae, 'speech');
      await tick();
      a.previews['Mae']!.completeError(StateError('offline'));
      await failed;
      expect(c.voice.previewError, isNotNull);

      c.changeSettings((s) => s.voices['speech'] = 'Mae');
      expect(c.voice.previewError, isNull);
      expect(c.voice.error, isNull);
      expect(c.voice.hint, isEmpty);
      await c.voice.stop();
      c.dispose();
      await audio.output.close();
    });

    test(
      'an unrelated change keeps it; a live call is never touched',
      () async {
        final (c, audio, a) = await make();
        c.changeSettings((s) {
          s.speechModel = 'speech';
          s.voices['speech'] = 'Atlas';
        });
        final failed = c.voice.playPreview(mae, 'speech');
        await tick();
        a.previews['Mae']!.completeError(StateError('offline'));
        await failed;
        final error = c.voice.error;
        c.changeSettings((s) => s.echoCancel = !s.echoCancel);
        expect(c.voice.error, error);
        c.changeSettings((s) => s.echoCancel = !s.echoCancel);

        await c.voice.start(c.current);
        c.voice.error = '麦克风被占用';
        c.changeSettings((s) => s.voices['speech'] = 'Mae');
        expect(c.voice.error, '麦克风被占用');
        await c.voice.stop();
        c.dispose();
        await audio.output.close();
      },
    );
  });
}
