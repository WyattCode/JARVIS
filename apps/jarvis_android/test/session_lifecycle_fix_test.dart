import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'support.dart';
import 'voice_support.dart';

class DeferredCatalogApi extends CatalogVoiceApi {
  Completer<List<ModelInfo>>? delayed;
  @override
  Future<List<ModelInfo>> models() => delayed?.future ?? super.models();
}

void main() {
  test(
    'starting call protects its owner and preserves subsequent messages',
    () async {
      final api = DeferredCatalogApi(),
          audio = FakeAudio(),
          vault = MemoryVault();
      final c = JarvisController(api, vault, audioDevice: audio);
      await c.initialize();
      await c.login('test', 'test');
      final owner = c.current, catalog = List<ModelInfo>.from(c.models);
      api.delayed = Completer<List<ModelInfo>>();
      final starting = c.voice.start(owner);
      await Future<void>.delayed(Duration.zero);
      expect(c.voice.active, isFalse);
      expect(c.deleteConversation(owner.id), isNull);
      expect(c.wipeConversations(), isFalse);
      api.delayed!.complete(catalog);
      await starting;
      expect(c.voice.active, isTrue);
      expect(c.voice.owner, same(owner));
      expect(c.conversations.contains(owner), isTrue);
      final session = api.wires.last.sent.firstWhere(
        (m) => m['type'] == 'session.update',
      )['session'];
      api.wires.last.server.add(
        jsonEncode({'type': 'session.updated', 'session': session}),
      );
      expect(c.voice.ready, isTrue);
      expect(c.voice.typed('review-marker-only'), isTrue);
      await c.save();
      expect(vault.value!.contains('review-marker-only'), isTrue);
      await c.voice.stop();
      c.dispose();
      await audio.output.close();
    },
  );
  test('fresh call has independent retry budget', () async {
    await runZoned(
      () async {
        final h = VoiceHarness();
        await h.session.start(h.owner);
        h.ack();
        try {
          for (var i = 0; i < 9; i++) {
            final count = h.api.wires.length;
            await h.wire.close();
            for (
              var n = 0;
              n < 100 && h.api.wires.length == count && h.session.active;
              n++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(h.session.active, isFalse);
          final before = h.api.wires.length;
          await h.session.start(h.owner).timeout(const Duration(seconds: 3));
          expect(h.session.active, isTrue);
          expect(h.api.wires.length, before + 1);
          await h.wire.close();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(h.session.active, isTrue);
          expect(h.api.wires.length, before + 2);
        } finally {
          await h.close();
        }
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final ms = duration.inMilliseconds;
          return parent.createTimer(
            zone,
            [1000, 2000, 4000, 8000, 15000].contains(ms)
                ? const Duration(milliseconds: 1)
                : duration,
            callback,
          );
        },
      ),
    );
  });
  test(
    'cancelling preparation drops late catalog and prevents socket creation',
    () async {
      final api = DeferredCatalogApi(), audio = FakeAudio();
      final c = JarvisController(api, MemoryVault(), audioDevice: audio);
      await c.initialize();
      await c.login('test', 'test');
      final catalog = List<ModelInfo>.from(c.models);
      api.delayed = Completer<List<ModelInfo>>();
      final pending = c.voice.start(c.current);
      await Future<void>.delayed(Duration.zero);
      await c.voice.stop();
      api.delayed!.complete(catalog);
      await pending;
      expect(c.voice.active, isFalse);
      expect(c.voice.starting, isFalse);
      expect(api.wires, isEmpty);
      c.dispose();
      await audio.output.close();
    },
  );
  test('invalidated owner cannot start after catalog refresh', () async {
    final api = DeferredCatalogApi(), audio = FakeAudio();
    final c = JarvisController(api, MemoryVault(), audioDevice: audio);
    await c.initialize();
    await c.login('test', 'test');
    final catalog = List<ModelInfo>.from(c.models), owner = c.current;
    api.delayed = Completer<List<ModelInfo>>();
    final pending = c.voice.start(owner);
    await Future<void>.delayed(Duration.zero);
    c.conversations.remove(owner);
    c.newConversation();
    api.delayed!.complete(catalog);
    await pending;
    expect(c.voice.active, isFalse);
    expect(api.wires, isEmpty);
    c.dispose();
    await audio.output.close();
  });
  test(
    'rejected update is retired and a valid replacement becomes ready',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.settings.voices['speech'] = 'retired';
      h.session.updateSettings();
      final rejected = h.wire.sent.lastWhere(
        (x) => x['type'] == 'session.update',
      )['event_id'];
      h.event({
        'type': 'error',
        'error': {'code': 'invalid_session', 'event_id': rejected},
      });
      expect(h.session.ready, isFalse);
      h.settings.voices['speech'] = 'Mae';
      h.session.updateSettings();
      h.ack(voice: 'Mae');
      expect(h.session.ready, isTrue);
      expect(h.session.error, isNull);
      h.event({
        'type': 'error',
        'error': {'code': 'invalid_session', 'event_id': rejected},
      });
      expect(h.session.ready, isTrue);
      expect(h.session.error, isNull);
      await h.close();
    },
  );
  test(
    'older refusal does not cancel the newer queued configuration',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.settings.voices['speech'] = 'retired';
      h.session.updateSettings();
      final old = h.wire.sent.lastWhere(
        (x) => x['type'] == 'session.update',
      )['event_id'];
      h.settings.voices['speech'] = 'Mae';
      h.session.updateSettings();
      h.event({
        'type': 'error',
        'error': {'code': 'invalid_session', 'event_id': old},
      });
      expect(h.session.error, isNull);
      expect(h.session.ready, isFalse);
      h.ack(voice: 'Mae');
      expect(h.session.ready, isTrue);
      await h.close();
    },
  );
  test(
    'legacy uncorrelated refusal retires the single pending request',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.event({
        'type': 'error',
        'error': {'code': 'invalid_session'},
      });
      h.session.updateSettings();
      h.ack();
      expect(h.session.ready, isTrue);
      await h.close();
    },
  );
}
