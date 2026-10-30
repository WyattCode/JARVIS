import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/startup_scene.dart';

import '../test/support.dart';

void main() {
  testWidgets('Record actual shared-reactor launch flight', (t) async {
    await t.runAsync(() async {
      final loader = FontLoader('JarvisPreview')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
              ).readAsBytes(),
            ),
          ),
        );
      await loader.load();
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
    });

    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(400, 869);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final controller = JarvisController(FakeApi(), MemoryVault());
    final key = GlobalKey();
    Future<void> show(bool ready) => t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('zh')],
          locale: const Locale('zh'),
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff3e899b),
              brightness: Brightness.dark,
            ).copyWith(primary: const Color(0xffe8e6df)),
            fontFamily: 'JarvisPreview',
          ),
          home: StartupGate(
            ready: ready,
            child: LoginPage(controller: controller),
          ),
        ),
      ),
    );
    final root = Directory('/home/user/.local/state/jarvis-028-morph-frames');
    await t.runAsync(() => root.create(recursive: true));
    Future<void> capture(int index) => t.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${root.path}/frame-${index.toString().padLeft(3, '0')}.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await show(false);
    await t.pump(const Duration(milliseconds: 100));
    await capture(0);
    await show(true);
    await t.pump();
    for (var i = 1; i <= 51; i++) {
      await t.pump(const Duration(milliseconds: 20));
      expect(t.takeException(), isNull);
      await capture(i);
    }
    await t.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
