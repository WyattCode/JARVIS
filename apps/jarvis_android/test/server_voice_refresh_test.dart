import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'support.dart';

class CatalogApi extends FakeApi {
  int revision = 1;
  String chosen = 'a';
  bool fail = false;
  Completer<List<ModelInfo>>? pending;
  @override
  Future<List<ModelInfo>> models() async {
    if (fail) throw StateError('offline');
    if (pending != null) return pending!.future;
    return [
      ModelInfo('chat', 'Chat'),
      ModelInfo.fromJson({
        'id': 'tts',
        'kind': 'speech',
        'default_voice': chosen,
        'voice_default_revision': revision,
        'voices': [
          {'id': chosen, 'name': 'Current'},
          {'id': chosen == 'a' ? 'b' : 'a', 'name': 'Other'},
        ],
      }),
    ];
  }
}

void main() {
  test(
    'refresh adopts a new server policy once and persists manual selection',
    () async {
      final api = CatalogApi(), vault = MemoryVault();
      final c = JarvisController(api, vault);
      addTearDown(c.dispose);
      await c.initialize();
      await c.login('test', 'test');
      expect(c.settings.voices['tts'], 'a');
      c.changeSettings((s) => s.voices['tts'] = 'b');
      await c.refreshVoiceCatalog();
      expect(c.settings.voices['tts'], 'b');
      api.revision = 2;
      await c.refreshVoiceCatalog();
      expect(c.settings.voices['tts'], 'a');
      c.changeSettings((s) => s.voices['tts'] = 'b');
      await c.save();
      expect(vault.value, contains('voiceDefaultRevisions'));
      await c.refreshVoiceCatalog();
      expect(c.settings.voices['tts'], 'b');
    },
  );
  test(
    'removed choice is replaced even when default revision was seen',
    () async {
      final api = CatalogApi(), c = JarvisController(api, MemoryVault());
      addTearDown(c.dispose);
      await c.initialize();
      await c.login('test', 'test');
      c.settings.voices['tts'] = 'retired';
      await c.refreshVoiceCatalog();
      expect(c.settings.voices['tts'], 'a');
    },
  );
  test(
    'failed or late refresh cannot replace a usable catalog after logout',
    () async {
      final api = CatalogApi();
      final live = JarvisController(api, MemoryVault());
      addTearDown(live.dispose);
      await live.initialize();
      await live.login('test', 'test');
      final before = live.models;
      api.fail = true;
      await live.refreshVoiceCatalog();
      expect(identical(live.models, before), isTrue);
      expect(live.authenticated, isTrue);
      api.fail = false;
      api.pending = Completer<List<ModelInfo>>();
      final pending = live.refreshVoiceCatalog();
      await Future<void>.delayed(Duration.zero);
      await live.logout();
      api.pending!.complete([ModelInfo('late', 'Late')]);
      await pending;
      expect(live.models.any((m) => m.id == 'late'), isFalse);
      expect(live.authenticated, isFalse);
    },
  );
}
