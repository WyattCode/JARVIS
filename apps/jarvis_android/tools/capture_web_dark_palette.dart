// Offline captures use the actual production JarvisApp theme; no model calls.
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/model/conversation.dart';

import '../test/support.dart';
import '../test/voice_support.dart';

void main() {
  testWidgets('Capture production dark theme across phone and foldable', (
    t,
  ) async {
    final output = Directory(
      Platform.environment['JARVIS_PALETTE_DIR'] ??
          '/home/user/.local/state/jarvis-030-palette',
    );
    output.createSync(recursive: true);
    await t.runAsync(() async {
      for (final font in [
        (
          'MaterialIcons',
          '/home/user/.local/opt/jarvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ),
        ('Roboto', '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'),
      ]) {
        final loader = FontLoader(font.$1)
          ..addFont(
            Future.value(
              ByteData.sublistView(await File(font.$2).readAsBytes()),
            ),
          );
        await loader.load();
      }
    });
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final tokens = <String, dynamic>{};
    Future<void> frames([int count = 65]) async {
      for (var i = 0; i < count; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
    }

    for (final shape in [
      ('ultra', 400.0, 869.0),
      ('outer', 425.0, 623.0),
      ('inner', 860.0, 608.0),
    ]) {
      t.view.physicalSize = Size(shape.$2, shape.$3);
      final c = JarvisController(
        VoiceApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      final key = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: key,
          child: JarvisApp(controller: c),
        ),
      );
      await frames();
      Future<void> capture(String name) async {
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${output.path}/${shape.$1}-$name.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('login');
      await c.login('Preview', 'test');
      await frames();
      await t.runAsync(
        () => precacheImage(
          const ResizeImage(
            AssetImage('assets/jarvis-icon-night.png'),
            width: 32,
          ),
          t.element(find.byType(MaterialApp)),
        ),
      );
      await frames(3);
      await capture('home');
      if (Platform.environment['JARVIS_CAPTURE_ACTIONS']=='1' && shape.$1=='inner') {
        await t.tap(find.byTooltip('会话操作').first);await frames(25);await capture('actions');
        await t.tapAt(const Offset(650,300));await frames(25);
      }
      final context = t.element(find.byType(Scaffold).first);
      final colors = Theme.of(context).colorScheme;
      String hex(Color v) => v.toARGB32().toRadixString(16);
      tokens[shape.$1] = {
        'surface': hex(colors.surface),
        'card': hex(colors.surfaceContainerLow),
        'raised': hex(colors.surfaceContainerHigh),
        'text': hex(colors.onSurface),
        'muted': hex(colors.onSurfaceVariant),
        'primary': hex(colors.primary),
        'border': hex(colors.outlineVariant),
      };
      c.current.messages.addAll([
        ChatMessage('user', '你好，帮我整理今天的计划。'),
        ChatMessage('assistant', '当然，我们先整理优先事项，再逐项安排时间。'),
      ]);
      c.changeSettings((s) {});
      await frames();
      await capture('chat');
      final nav = t
          .widget<MaterialApp>(find.byType(MaterialApp))
          .navigatorKey!
          .currentState!;
      nav.push(
        MaterialPageRoute<void>(builder: (_) => SettingsPage(controller: c)),
      );
      await frames();
      await capture('settings');
      await t.ensureVisible(find.byKey(const Key('message-font-size')));
      await frames(3);
      await t.tap(find.byKey(const Key('message-font-size')));
      await frames(20);
      await t.tap(find.text('20').last);
      await frames(20);
      expect(c.settings.messageFontSize, 20);
      nav.pop();
      await frames();
      await capture('font-20');
      await t.pumpWidget(const SizedBox());
      await t.pump();
    }
    File('${output.path}/tokens.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(tokens));
  });
}
