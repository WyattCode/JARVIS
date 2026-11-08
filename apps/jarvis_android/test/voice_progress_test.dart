import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'voice_support.dart';

/// Where the voice is in the reply, and holding it, as the iOS call page has it.
void main() {
  Future<VoiceHarness> started() async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    return h;
  }

  /// A reply of [seconds] of sound (24 kHz, 16 bit) with its words.
  void reply(VoiceHarness h, String words, double seconds) {
    h.event({
      'type': 'response.created',
      'response': {'id': 'r1'},
    });
    h.event({
      'type': 'response.audio_transcript.delta',
      'response_id': 'r1',
      'item_id': 'i1',
      'delta': words,
    });
    h.event({
      'type': 'response.audio.delta',
      'response_id': 'r1',
      'item_id': 'i1',
      'delta': base64Encode(Uint8List((seconds * 24000).round() * 2)),
    });
  }

  void playing(VoiceHarness h, int bufferedFrames, {bool active = true}) =>
      h.audio.output.add({
        'type': 'playback',
        'active': active,
        'buffered_frames': bufferedFrames,
        'sample_rate': 24000,
        'rms': .1,
      });

  test('nothing is followed before any of the sound is heard', () async {
    final h = await started();
    reply(h, '你好，世界。', 1);
    await Future<void>.delayed(Duration.zero);
    expect(h.session.speechProgress, isNull);
    await h.close();
  });

  test('progress is what arrived less what the player still holds', () async {
    final h = await started();
    reply(h, '你好，世界。', 2);
    await Future<void>.delayed(Duration.zero);
    playing(h, 48000); // all of it still waits: nothing heard
    expect(h.session.speechProgress!.played, 0);
    expect(h.session.speechProgress!.live, isTrue);
    playing(h, 24000); // one second left of two: one second heard
    final p = h.session.speechProgress!;
    expect(p.played, closeTo(1, 1e-9));
    expect(p.live, isTrue);
    expect(p.cut, isFalse);
    expect(p.total, isNull, reason: 'the reply is still being made');
    await h.close();
  });

  test(
    'once all the sound is here its length sets the voice\'s pace',
    () async {
      final h = await started();
      reply(h, '你好，世界。', 2);
      await Future<void>.delayed(Duration.zero);
      playing(h, 24000);
      h.event({'type': 'response.audio.done', 'response_id': 'r1'});
      h.event({
        'type': 'response.done',
        'response': {'id': 'r1', 'status': 'completed', 'output': []},
      });
      final p = h.session.speechProgress!;
      expect(p.total, closeTo(2, 1e-9));
      await h.close();
    },
  );

  test('a marker in the middle of a reply does not close its sound', () async {
    final h = await started();
    reply(h, '你好，世界。', 1);
    await Future<void>.delayed(Duration.zero);
    playing(h, 12000);
    // A paragraph ends, and the reply goes on.
    h.event({'type': 'response.audio.done', 'response_id': 'r1'});
    h.event({
      'type': 'response.audio.delta',
      'response_id': 'r1',
      'item_id': 'i1',
      'delta': base64Encode(Uint8List(48000)),
    });
    h.event({
      'type': 'response.done',
      'response': {'id': 'r1', 'status': 'completed', 'output': []},
    });
    expect(h.session.speechProgress!.total, isNull);
    await h.close();
  });

  test('a reply cut off keeps the place it had reached', () async {
    final h = await started();
    reply(h, '你好，世界。', 2);
    await Future<void>.delayed(Duration.zero);
    playing(h, 24000);
    await h.session.interrupt();
    final p = h.session.speechProgress!;
    expect(p.cut, isTrue);
    expect(p.live, isFalse);
    expect(p.played, closeTo(1, 1e-9));
    await h.close();
  });

  test('a voice preview is not followed', () async {
    final h = await started();
    h.session.previewing = true;
    reply(h, '你好', 1);
    await Future<void>.delayed(Duration.zero);
    playing(h, 100);
    expect(h.session.speechProgress, isNull);
    await h.close();
  });

  group('holding the voice', () {
    test('a tap holds it and the next one lets it go on', () async {
      final h = await started();
      reply(h, '你好，世界。', 2);
      await Future<void>.delayed(Duration.zero);
      playing(h, 24000);
      expect(h.session.speaking, isTrue);
      expect(h.session.togglePlaybackPause(), isTrue);
      expect(h.session.playbackPaused, isTrue);
      expect(h.audio.pauses, [true]);
      expect(h.session.togglePlaybackPause(), isTrue);
      expect(h.session.playbackPaused, isFalse);
      expect(h.audio.pauses, [true, false]);
      await h.close();
    });

    test('there is nothing to hold when nothing is said', () async {
      final h = await started();
      expect(h.session.togglePlaybackPause(), isFalse);
      expect(h.audio.pauses, isEmpty);
      await h.close();
    });

    test('a reply that is over is no longer held', () async {
      final h = await started();
      reply(h, '你好', 1);
      await Future<void>.delayed(Duration.zero);
      playing(h, 12000);
      h.session.togglePlaybackPause();
      h.event({
        'type': 'response.done',
        'response': {'id': 'r1', 'status': 'completed', 'output': []},
      });
      playing(h, 0, active: false);
      expect(h.session.playbackPaused, isFalse);
      expect(h.audio.pauses, [true, false]);
      await h.close();
    });

    test(
      'an interruption clears a held voice, and the clear lets it go',
      () async {
        final h = await started();
        reply(h, '你好', 1);
        await Future<void>.delayed(Duration.zero);
        playing(h, 12000);
        h.session.togglePlaybackPause();
        await h.session.interrupt();
        expect(h.session.playbackPaused, isFalse);
        // No play of the old speech first: the clear is what releases the hold.
        expect(h.audio.pauses, [true]);
        expect(h.audio.flushes, 1);
        await h.close();
      },
    );
  });

  group('after review', () {
    test(
      'a held reply does not trip the backlog guard that ends a reply',
      () async {
        final h = await started();
        reply(h, '你好', 2);
        await Future<void>.delayed(Duration.zero);
        playing(h, 24000);
        expect(h.session.togglePlaybackPause(), isTrue);
        // Half a minute of sound arrives while the voice is held.
        h.event({
          'type': 'response.audio.delta',
          'response_id': 'r1',
          'item_id': 'i1',
          'delta': base64Encode(Uint8List(1500000)),
        });
        await Future<void>.delayed(Duration.zero);
        expect(h.session.error, isNull);
        expect(h.session.playbackPaused, isTrue);
        await h.close();
      },
    );

    test('the same sound, not held, is cut as a backlog', () async {
      final h = await started();
      reply(h, '你好', 2);
      await Future<void>.delayed(Duration.zero);
      playing(h, 24000);
      h.event({
        'type': 'response.audio.delta',
        'response_id': 'r1',
        'item_id': 'i1',
        'delta': base64Encode(Uint8List(1500000)),
      });
      await Future<void>.delayed(Duration.zero);
      expect(h.session.error, isNotNull);
      await h.close();
    });

    test('a held voice makes no level and no light', () async {
      final h = await started();
      reply(h, '你好', 2);
      await Future<void>.delayed(Duration.zero);
      h.audio.output.add({
        'type': 'playback',
        'active': true,
        'buffered_frames': 24000,
        'sample_rate': 24000,
        'rms': .5,
      });
      expect(h.session.levels.value.output, .5);
      h.session.togglePlaybackPause();
      expect(h.session.levels.value.output, 0);
      expect(h.session.levels.value.playing, isFalse);
      h.audio.output.add({
        'type': 'playback',
        'active': true,
        'buffered_frames': 24000,
        'sample_rate': 24000,
        'rms': .5,
      });
      expect(h.session.levels.value.output, 0);
      await h.close();
    });

    test('stopping to recover keeps the call page open', () async {
      final h = await started();
      expect(h.session.open, isTrue);
      await h.session.stop(keepOpen: true);
      expect(h.session.open, isTrue);
      await h.session.stop();
      expect(h.session.open, isFalse);
      await h.close();
    });
  });
}
