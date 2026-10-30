// Optional offline Flutter renderer: no real server or phone calls.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import '../test/support.dart';
import '../test/voice_support.dart';

import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/ui/settings_page.dart';

void main() {
  testWidgets('Capture offline foldable layouts', (t) async {
    final output = Platform.environment['JARVIS_PREVIEW_DIR'];
    if (output == null) {
      throw StateError('Set JARVIS_PREVIEW_DIR to an output folder');
    }
    await t.runAsync(() async {
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/home/user/.local/opt/jarvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        );
      await icons.load();
      final file = File(
        '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
      );
      if (await file.exists()) {
        final loader = FontLoader('JarvisPreview')
          ..addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          );
        await loader.load();
      }
    });
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    for (final profile in [
      ('outer', 425.0, 623.0),
      ('ultra', 400.0, 869.0),
      ('outer-landscape', 623.0, 425.0),
      ('inner-portrait', 608.0, 860.0),
      ('inner-landscape', 860.0, 608.0),
    ]) {
      final c = JarvisController(
        VoiceApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      await c.initialize();
      await c.login('user', 'test');
      t.view.physicalSize = Size(profile.$2, profile.$3);
      final key = GlobalKey();
      Widget screen = JarvisHome(controller: c);
      final dark = Platform.environment['JARVIS_PREVIEW_DARK'] == '1';
      final colors =
          ColorScheme.fromSeed(
            seedColor: const Color(0xff3e899b),
            brightness: dark ? Brightness.dark : Brightness.light,
          ).copyWith(
            surface: dark ? const Color(0xff0d0d0f) : const Color(0xfffbf9f2),
            primary: dark ? const Color(0xffe8e6df) : const Color(0xff28596a),
            surfaceContainerLow: dark ? const Color(0xff20201f) : null,
            surfaceContainerHighest: dark ? const Color(0xff323230) : null,
          );
      Future<void> capture(String filename) async {
        await t.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              supportedLocales: const [Locale('zh')],
              locale: const Locale('zh'),
              theme: ThemeData(
                useMaterial3: true,
                colorScheme: colors,
                fontFamily: 'JarvisPreview',
                scaffoldBackgroundColor: colors.surface,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
              home: screen,
            ),
          ),
        );
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final render =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await render.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final path = Directory(output);
          await path.create(recursive: true);
          await File('${path.path}/$filename.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture(profile.$1);
      c.models.add(
        ModelInfo(
          'speech',
          'Drama 3',
          kind: 'speech',
          defaultVoice: 'Atlas',
          voices: const [
            VoiceInfo('Atlas', 'Atlas', 'A clear, steady voice'),
            VoiceInfo('Mae', 'Mae', 'A warm, expressive voice'),
          ],
        ),
      );
      c.settings.speechModel = 'speech';
      c.settings.voices['speech'] = 'Atlas';
      await t.runAsync(() => c.voice.start(c.current));
      c.voice.handle({
        'type': 'session.updated',
        'session': {
          'speech_model': 'speech',
          'voice': 'Atlas',
          'reasoning': true,
        },
      });
      await capture('voice-empty-${profile.$1}');
      c.voice.lastYou = '你好，帮我整理一下今天的计划。';
      c.voice.lastBot = '好的。先把最重要的事情告诉我，我们一起按时间和优先级安排。';
      c.notifyDraftSuggestion();
      await capture('voice-${profile.$1}');
      // Alternate fake-clock and real I/O zones while the test-only socket closes.
      var closed = false;
      c.voice.stop().then((_) {
        closed = true;
      });
      for (var i = 0; i < 100 && !closed; i++) {
        await t.pump();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
      expect(closed, true);
      screen = SettingsPage(controller: c);
      await capture('settings-${profile.$1}');
      await t.pumpWidget(const SizedBox());
      c.dispose();
    }
  });
}
