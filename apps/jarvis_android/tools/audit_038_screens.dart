import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/ui/status_page.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import '../test/support.dart';
import '../test/voice_support.dart';
import '../test/voice_layout_test.dart' show LayoutApi, settleTask;

class AuditApi extends LayoutApi {
  @override
  Future<Map<String, dynamic>> toolsStatus() async => {
    'mem_available_bytes': 50 * 1073741824,
    'data': [
      {'name': 'Qwen3.8-Flash-Next', 'state': 'ready'},
      {'name': '语音识别', 'state': 'ready'},
      {'name': '语音合成 · Atlas', 'state': 'ready'},
      {'name': '图片与视频生成', 'state': 'idle'},
    ],
  };
}

void main() {
  testWidgets('Audit production phone and fold screens in both themes', (
    t,
  ) async {
    final out = Directory(
      Platform.environment['JARVIS_AUDIT_DIR'] ??
          '/home/user/.local/state/jarvis-audit-037-current/flow-before',
    )..createSync(recursive: true);
    await t.runAsync(() async {
      for (final f in [
        ('Roboto', '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'),
        (
          'MaterialIcons',
          '/home/user/.local/opt/jarvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ),
      ]) {
        final font = FontLoader(f.$1)
          ..addFont(
            Future.value(ByteData.sublistView(await File(f.$2).readAsBytes())),
          );
        await font.load();
      }
    });
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final seed = JarvisController(FakeApi(), MemoryVault());
    await t.pumpWidget(JarvisApp(controller: seed));
    await t.pump();
    final app = t.widget<MaterialApp>(find.byType(MaterialApp));
    final themes = [('dark', app.darkTheme!), ('light', app.theme!)];
    await t.pumpWidget(const SizedBox());
    Future<void> frames() async {
      for (var i = 0; i < 25; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
    }

    final notes = <Map<String, dynamic>>[];
    for (final shape in [
      ('ultra', 400.0, 869.0),
      ('outer', 425.0, 623.0),
      ('inner', 860.0, 608.0),
    ]) {
      t.view.physicalSize = Size(shape.$2, shape.$3);
      for (final theme in themes) {
        final c = JarvisController(
          AuditApi(),
          MemoryVault(),
          audioDevice: FakeAudio(),
        );
        await c.initialize();
        await c.login('Audit', 'test');
        c.theme = theme.$1;
        final key = GlobalKey();
        Future<void> capture(String screen, Widget page) async {
          await t.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                theme: theme.$2,
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: true),
                  child: child!,
                ),
                home: page,
              ),
            ),
          );
          await frames();
          final errors = <String>[];
          Object? error;
          while ((error = t.takeException()) != null) {
            errors.add(error.toString());
          }
          final name = '${shape.$1}-${theme.$1}-$screen';
          notes.add({
            'case': name,
            'errors': errors,
            'voice_hint': screen == 'voice-idle' ? c.voice.hint : null,
          });
          await t.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            File('${out.path}/$name.png')
                .writeAsBytesSync(data!.buffer.asUint8List());
            image.dispose();
          });
          await t.pumpWidget(const SizedBox());
        }

        await capture('settings', SettingsPage(controller: c));
        await capture('status', StatusPage(controller: c));
        await t.runAsync(() => c.voice.start(c.current));
        c.voice.handle({
          'type': 'session.updated',
          'session': {
            'speech_model': 'speech',
            'voice': 'Atlas',
            'model': 'chat--high',
            'reasoning': true,
          },
        });
        await t.runAsync(() async {
          await c.voice.hold();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        c.voice.handle({'type': 'input_audio_buffer.cleared'});
        c.voice.release();
        await t.pump(const Duration(milliseconds: 250));
        c.voice.handle({
          'type': 'input_audio_buffer.committed',
          'item_id': 'u',
        });
        c.voice.handle({
          'type': 'conversation.item.input_audio_transcription.completed',
          'item_id': 'u',
          'transcript': '你好，介绍一下贾维斯。',
        });
        c.voice.handle({
          'type': 'response.created',
          'response': {'id': 'r'},
        });
        c.voice.handle({
          'type': 'response.text.delta',
          'response_id': 'r',
          'item_id': 'b',
          'delta': '你好，我是贾维斯。我可以陪你聊天、整理资料和创作内容。',
        });
        c.voice.handle({
          'type': 'response.done',
          'response': {'id': 'r', 'status': 'completed'},
        });
        await capture('voice-idle', VoicePage(controller: c));
        if (Platform.environment['JARVIS_CAPTURE_STALE_ERROR'] == '1') {
          c.settings.voiceMode = 'vad';
          c.voice.handle({
            'type': 'input_audio_buffer.committed',
            'item_id': 'bad',
          });
          c.voice.handle({
            'type': 'conversation.item.input_audio_transcription.completed',
            'item_id': 'bad',
            'transcript': '',
          });
          c.settings.voiceMode = 'ptt';
          await capture('voice-empty-input', VoicePage(controller: c));
          c.voice.handle({
            'type': 'response.created',
            'response': {'id': 'retry'},
          });
          c.voice.handle({
            'type': 'response.text.delta',
            'response_id': 'retry',
            'item_id': 'retry-bot',
            'delta': '我已经听清楚了，可以继续对话。',
          });
          c.voice.handle({
            'type': 'response.done',
            'response': {'id': 'retry', 'status': 'completed'},
          });
          await capture('voice-retry-reply', VoicePage(controller: c));
          (c.audioDevice! as FakeAudio).output.add({
            'type': 'playback',
            'active': true,
            'rms': .06,
          });
          await capture('voice-speaking', VoicePage(controller: c));
          if (Platform.environment['JARVIS_CAPTURE_ACK'] == '1') {
            c.voice.updateSettings();
            c.voice.handle({
              'type': 'session.updated',
              'session': {
                'speech_model': 'speech',
                'voice': 'Atlas',
                'model': 'chat--high',
                'reasoning': true,
              },
            });
            await capture('voice-after-config-ack', VoicePage(controller: c));
          }

          (c.audioDevice! as FakeAudio).output.add({
            'type': 'playback',
            'active': false,
            'rms': 0.0,
          });

          await t.runAsync(c.voice.hold);
          await capture('voice-held', VoicePage(controller: c));
        }

        await settleTask(t, c.voice.stop());
        c.dispose();
      }
    }
    File('${out.path}/metrics.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(notes));
  });
}
