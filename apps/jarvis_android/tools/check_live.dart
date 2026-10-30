// Explicit, bounded integration check. Credentials are read from a private local
// file, never printed, persisted, embedded in source or placed in process args.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/model/settings.dart';
import 'package:jarvis_android/net/realtime_wire.dart';
import 'package:jarvis_android/voice/pcm.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tools/check_live.dart PRIVATE_CREDENTIAL_FILE [--chat] [--preview]',
    );
    exitCode = 2;
    return;
  }
  final contents = await File(args.first).readAsString();
  String field(String name) {
    final match = RegExp(
      '^$name[：:]\\s*(.+)\\s*\$',
      multiLine: true,
    ).firstMatch(contents);
    if (match == null) throw StateError('Missing private credential field');
    return match.group(1)!.trim();
  }

  final api = JarvisApi(Uri.parse('https://jarvis.example.com'));
  RealtimeWire? wire;
  try {
    await api.login(field('账户'), field('密码'));
    final models = await api.models();
    final chats = models.where((m) => m.kind == 'chat').toList();
    if (chats.isEmpty) throw StateError('No chat model');
    wire = await api.openRealtime();
    final events = StreamIterator(wire.events);
    if (!await events.moveNext().timeout(const Duration(seconds: 10))) {
      throw StateError('No session event');
    }
    final event = jsonDecode(events.current) as Map;
    final result = <String, dynamic>{
      'tls_verified': true,
      'authenticated': api.cookie != null,
      'catalog_count': models.length,
      'chat_model': chats.first.id,
      'speech_voices': models
          .where((m) => m.kind == 'speech')
          .fold<int>(0, (n, m) => n + m.voices.length),
      'websocket_event': event['type'],
    };
    final speaker = models.where((m) => m.kind == 'speech').firstOrNull;
    if (speaker != null) {
      final alias =
          chats.first.metadata['jarvis']?['voice_effort_models']?['high']
              as String? ??
          chats.first.id;
      wire.send(
        jsonEncode({
          'type': 'session.update',
          'session': {
            'model': alias,
            'reasoning': true,
            'speech_model': speaker.id,
            'voice': speaker.defaultVoice,
            'modalities': ['audio', 'text'],
            'input_audio_format': 'pcm16',
            'output_audio_format': 'pcm16',
            'turn_detection': null,
          },
        }),
      );
      Map? ack;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline) &&
          await events.moveNext().timeout(const Duration(seconds: 15))) {
        final e = jsonDecode(events.current) as Map;
        if (e['type'] == 'session.updated') {
          ack = e['session'] as Map;
          break;
        }
        if (e['type'] == 'error') {
          throw StateError('Server rejected voice configuration');
        }
      }
      if (ack == null) {
        throw StateError('No voice configuration acknowledgement');
      }
      result['voice_config_confirmed'] =
          ack['model'] == alias &&
          ack['reasoning'] == true &&
          ack['speech_model'] == speaker.id &&
          ack['voice'] == speaker.defaultVoice;
      if (result['voice_config_confirmed'] != true) {
        throw StateError('Voice configuration mismatch');
      }
      if (args.contains('--preview')) {
        final v = speaker.voices.firstWhere(
          (v) => v.id == speaker.defaultVoice,
        );
        final clip = PcmClip.wav(await api.preview(v, speaker.id));
        result['voice_preview_rate'] = clip.rate;
        result['voice_preview_pcm_bytes'] = clip.bytes.length;
      }
    }
    await events.cancel();
    await wire.close();
    wire = null;
    if (args.contains('--chat')) {
      var content = '', done = false;
      await for (final delta in api.chat(
        'native_integration_check',
        chats.first.id,
        'none',
        [
          {'role': 'user', 'content': '这是一条客户端连通性测试。只回答：连接正常。'},
        ],
        options: const ChatOptions(maxTokens: 128),
      )) {
        content += delta.text;
        done = done || delta.done;
      }
      result['chat_completed'] = done;
      result['chat_answer_matches'] = content.contains('连接正常');
      result['answer_chars'] = content.length;
    }
    stdout.writeln(jsonEncode(result));
  } catch (e) {
    stderr.writeln(
      jsonEncode({
        'success': false,
        'error_type': e.runtimeType.toString(),
        'detail': e is JarvisException
            ? e.message
            : 'Live check failed; credentials and headers omitted',
      }),
    );
    exitCode = 1;
  } finally {
    await wire?.close();
    try {
      await api.logout();
    } catch (_) {}
    api.close();
  }
}
