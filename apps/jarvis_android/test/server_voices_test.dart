import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/model/settings.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'http_api_test.dart' show Client, Reply;
import 'support.dart';
import 'voice_support.dart';

/// A server whose voice catalog the test edits between calls.
class CatalogApi extends VoiceApi {
  CatalogApi(this.origin);
  final String origin;
  List<ModelInfo> catalog = [];
  bool fail = false;
  int calls = 0;
  @override
  Uri get endpoint => Uri.parse(origin);
  @override
  Future<List<ModelInfo>> models() async {
    calls++;
    if (fail) throw const JarvisException('offline');
    return [ModelInfo('chat', 'Chat'), ...catalog];
  }
}

ModelInfo engine(
  String defaultVoice,
  int revision, [
  List<String> voices = const ['v1', 'v2', 'v3'],
]) => ModelInfo(
  's',
  'Engine',
  kind: 'speech',
  defaultVoice: defaultVoice,
  voiceCatalogRevision: revision,
  voiceDefaultRevision: revision,
  voices: [for (final v in voices) VoiceInfo(v, 'name $v', 'about $v')],
);

Future<JarvisController> signedIn(CatalogApi api) async {
  final c = JarvisController(api, MemoryVault(), audioDevice: FakeAudio());
  await c.initialize();
  await c.login('user', 'x');
  return c;
}

void main() {
  group('the server describes the voices', () {
    test('order, ids, names, descriptions, previews and default are taken as given', () {
      final model = ModelInfo.fromJson({
        'id': 'e',
        'kind': 'speech',
        'default_voice': 'c',
        'voice_catalog_revision': 5,
        'voice_default_revision': 4,
        'voices': [
          {
            'id': 'c',
            'name': 'Cee',
            'description': 'first',
            'preview_url': '/p/c.wav',
          },
          {'id': 'a', 'name': 'Ay', 'description': 'second'},
          'b',
        ],
      });
      expect(model.voices.map((v) => v.id), ['c', 'a', 'b']);
      expect(model.voices.map((v) => v.name), ['Cee', 'Ay', 'b']);
      expect(model.voices.first.description, 'first');
      expect(model.voices.first.preview, '/p/c.wav');
      expect(model.voices[1].preview, isNull);
      expect(model.defaultVoice, 'c');
      expect(model.voiceCatalogRevision, 5);
      expect(model.voiceDefaultRevision, 4);
    });

    test('a server without a default or revisions yields none', () {
      final model = ModelInfo.fromJson({
        'id': 'e',
        'kind': 'speech',
        'voices': ['b', 'a'],
      });
      expect(model.defaultVoice, '');
      expect(model.voices.first.id, 'b');
      expect(model.voiceCatalogRevision, 0);
      expect(model.voiceDefaultRevision, 0);
    });

    test('revisions on the list itself reach the speech engines, and the engine own wins', () async {
      final body = jsonEncode({
        'voice_catalog_revision': 2,
        'voice_default_revision': 2,
        'data': [
          {'id': 'chat', 'kind': 'chat'},
          {
            'id': 'e1',
            'kind': 'speech',
            'voices': ['a'],
          },
          {
            'id': 'e2',
            'kind': 'speech',
            'voice_default_revision': 7,
            'voices': ['a'],
          },
        ],
      });
      final api = JarvisApi(
        Uri.parse('https://jarvis.test'),
        clientFactory: () => Client(Reply(200, [utf8.encode(body)])),
      )..cookie = 'cookie=test';
      final found = {for (final m in await api.models()) m.id: m};
      expect(found['e1']!.voiceCatalogRevision, 2);
      expect(found['e1']!.voiceDefaultRevision, 2);
      expect(found['e2']!.voiceCatalogRevision, 2);
      expect(found['e2']!.voiceDefaultRevision, 7);
      expect(found['chat']!.voiceCatalogRevision, 0);
    });

    test('the applied default revisions are saved by server and engine', () {
      expect(ChatSettings().voices, isEmpty);
      final s = ChatSettings()..voiceDefaultRevisions['https://a|s'] = 2;
      final back = ChatSettings()
        ..restore({
          ...s.toJson(),
          // An older build kept a number of its own; it means nothing now.
          'atlasVoiceDefaultRevision': 1,
        });
      expect(back.voiceDefaultRevisions, {'https://a|s': 2});
      expect(back.toJson().containsKey('atlasVoiceDefaultRevision'), isFalse);
    });
  });

  group('the default voice of the server', () {
    test(
      'is taken when the app connects, and recorded for that server and engine',
      () async {
        final api = CatalogApi('https://a.test')..catalog = [engine('v2', 2)];
        final c = await signedIn(api);
        expect(c.settings.voices['s'], 'v2');
        expect(c.settings.voiceDefaultRevisions['https://a.test|s'], 2);
        c.dispose();
      },
    );

    test('is not forced again at the same revision: the voice picked by the user stays', () async {
      final api = CatalogApi('https://a.test')..catalog = [engine('v2', 2)];
      final c = await signedIn(api);
      c.changeSettings((s) => s.voices['s'] = 'v3');
      await c.connect();
      await c.refreshVoiceCatalog();
      expect(c.settings.voices['s'], 'v3');
      c.dispose();
    });

    test('is taken once when the server raises the revision, then the pick stays again', () async {
      final api = CatalogApi('https://a.test')..catalog = [engine('v2', 2)];
      final c = await signedIn(api);
      c.changeSettings((s) => s.voices['s'] = 'v3');
      api.catalog = [engine('v1', 3)];
      await c.refreshVoiceCatalog();
      expect(c.settings.voices['s'], 'v1');
      expect(c.settings.voiceDefaultRevisions['https://a.test|s'], 3);
      c.changeSettings((s) => s.voices['s'] = 'v2');
      await c.refreshVoiceCatalog();
      await c.connect();
      expect(c.settings.voices['s'], 'v2');
      c.dispose();
    });

    test('is tracked per server', () async {
      final api = CatalogApi('https://b.test')..catalog = [engine('v1', 2)];
      final c = JarvisController(api, MemoryVault(), audioDevice: FakeAudio());
      await c.initialize();
      c.settings.voices['s'] = 'v3';
      c.settings.voiceDefaultRevisions['https://a.test|s'] = 2;
      await c.login('user', 'x');
      expect(
        c.settings.voices['s'],
        'v1',
        reason: 'server b was not applied yet',
      );
      c.dispose();
    });

    test('is not applied to a call in progress, only after it', () async {
      final api = CatalogApi('https://a.test')..catalog = [engine('v2', 2)];
      final c = await signedIn(api);
      c.changeSettings((s) => s.voices['s'] = 'v3');
      await c.voice.start(c.current);
      expect(c.voice.active, isTrue);
      api.catalog = [engine('v1', 3)];
      await c.refreshVoiceCatalog();
      expect(c.settings.voices['s'], 'v3', reason: 'the call keeps its voice');
      expect(c.settings.voiceDefaultRevisions['https://a.test|s'], 2);
      await c.voice.stop();
      await c.refreshVoiceCatalog();
      expect(c.settings.voices['s'], 'v1');
      expect(c.settings.voiceDefaultRevisions['https://a.test|s'], 3);
      c.dispose();
    });
  });

  group('refreshing the voice list', () {
    test('follows the server: order, names, previews and default', () async {
      final api = CatalogApi('https://a.test')..catalog = [engine('v2', 2)];
      final c = await signedIn(api);
      api.catalog = [
        engine('v3', 3, ['v3', 'v1']),
      ];
      await c.refreshVoiceCatalog();
      final speech = c.models.firstWhere((m) => m.kind == 'speech');
      expect(speech.voices.map((v) => v.id), ['v3', 'v1']);
      expect(speech.voiceCatalogRevision, 3);
      expect(c.models.where((m) => m.kind == 'chat'), isNotEmpty);
      c.dispose();
    });

    test(
      'keeps what is known when the request fails or the answer has no engine',
      () async {
        final api = CatalogApi('https://a.test')..catalog = [engine('v2', 2)];
        final c = await signedIn(api);
        api.fail = true;
        await c.refreshVoiceCatalog();
        api.fail = false;
        api.catalog = [];
        await c.refreshVoiceCatalog();
        final speech = c.models.firstWhere((m) => m.kind == 'speech');
        expect(speech.voices.map((v) => v.id), ['v1', 'v2', 'v3']);
        expect(c.settings.voices['s'], 'v2');
        expect(c.error, isNull);
        expect(c.authenticated, isTrue);
        c.dispose();
      },
    );

    test('asks once for refreshes that overlap', () async {
      final api = CatalogApi('https://a.test')..catalog = [engine('v2', 2)];
      final c = await signedIn(api);
      final before = api.calls;
      await Future.wait([c.refreshVoiceCatalog(), c.refreshVoiceCatalog()]);
      expect(api.calls - before, 1);
      c.dispose();
    });
  });

  group('trying a voice out', () {
    JarvisApi apiWith(Client Function() make) =>
        JarvisApi(Uri.parse('https://jarvis.test'), clientFactory: make)
          ..cookie = 'cookie=test';

    test(
      'uses the clip of the server, resolved against the server address',
      () async {
        final clients = <Client>[];
        final api = apiWith(() {
          final client = Client(Reply(200, [wavBytes()]));
          clients.add(client);
          return client;
        });
        final bytes = await api.preview(
          const VoiceInfo('a', 'A', '', preview: '/v1/voices/a/preview.wav'),
          's',
        );
        expect(bytes, wavBytes());
        expect(clients.single.request!.method, 'GET');
        expect(
          clients.single.request!.url.toString(),
          'https://jarvis.test/v1/voices/a/preview.wav',
        );
      },
    );

    test('speaks the one sentence when there is no clip, or the clip cannot be fetched', () async {
      for (final voice in const [
        VoiceInfo('a', 'A', ''),
        VoiceInfo('a', 'A', '', preview: '/missing.wav'),
      ]) {
        final clients = <Client>[];
        final api = apiWith(() {
          final client = Client(
            Reply(clients.isEmpty && voice.preview != null ? 404 : 200, [
              wavBytes(),
            ]),
          );
          clients.add(client);
          return client;
        });
        await api.preview(voice, 's');
        final request = clients.last.request!;
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/audio/speech');
        final body = jsonDecode(utf8.decode(request.bytes)) as Map;
        expect(body['input'], previewSentence);
        expect(body['voice'], 'a');
      }
      expect(previewSentence, '你好，我是贾维斯。我们把问题理清楚，一步一步找到答案。');
    });
  });

  group('a clip that cannot be played', () {
    test('is replaced by the voice speaking the sentence instead of failing the try-out', () async {
      final h = VoiceHarness();
      const withClip = VoiceInfo('Atlas', 'Atlas', '', preview: '/clip.mp3');
      final run = h.session.playPreview(withClip, 'speech');
      await Future<void>.delayed(Duration.zero);
      h.api.previews['Atlas']!.complete(
        utf8.encode('not a wav file at all, not even close, not at all......'),
      );
      await run;
      expect(h.api.synthesized, ['Atlas']);
      expect(h.session.previewError, isNull);
      expect(h.audio.clips, hasLength(1));
      await h.close();
    });

    test(
      'without a clip from the server the failure is reported as before',
      () async {
        final h = VoiceHarness();
        const plain = VoiceInfo('Atlas', 'Atlas', '');
        final run = h.session.playPreview(plain, 'speech');
        await Future<void>.delayed(Duration.zero);
        h.api.previews['Atlas']!.complete(
          utf8.encode(
            'not a wav file at all, not even close, not at all......',
          ),
        );
        await run;
        expect(h.api.synthesized, isEmpty);
        expect(h.session.previewError, contains('试听'));
        await h.close();
      },
    );

    test('a clip larger than a few seconds of speech is refused', () async {
      final big = Uint8List(9 * 1024 * 1024);
      final api = JarvisApi(
        Uri.parse('https://jarvis.test'),
        clientFactory: () => Client(Reply(200, [big])),
      )..cookie = 'cookie=test';
      // The clip is refused, so the sentence is spoken instead; that answer is the same fake and is just as large,
      // which fails too: the point is that nothing 9 MB is accepted as a clip.
      await expectLater(
        api.preview(const VoiceInfo('a', 'A', '', preview: '/big.wav'), 's'),
        throwsA(isA<JarvisException>()),
      );
    });
  });

  test(
    'a call that is starting keeps its voice like one in progress',
    () async {
      final api = CatalogApi('https://a.test')..catalog = [engine('v2', 2)];
      final c = await signedIn(api);
      c.changeSettings((s) => s.voices['s'] = 'v3');
      api.catalog = [engine('v1', 3)];
      final start = c.voice.start(c.current);
      await c.refreshVoiceCatalog();
      expect(c.settings.voices['s'], 'v3');
      await start;
      await c.voice.stop();
      c.dispose();
    },
  );
}
