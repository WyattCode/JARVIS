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

void main() {
  testWidgets('Capture production login on compact and unfolded screens', (
    t,
  ) async {
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
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetViewInsets);
    final c = JarvisController(FakeApi(), MemoryVault());
    final output = Directory('/home/user/.local/state/jarvis-reactor-layouts');
    await t.runAsync(() => output.create(recursive: true));
    for (final dark in [true, false]) {
      for (final profile in [
        ('outer', 425.0, 623.0),
        ('ultra', 400.0, 869.0),
        ('ultra-keyboard', 400.0, 869.0),
        ('inner-landscape', 860.0, 608.0),
      ]) {
        t.view.physicalSize = Size(profile.$2, profile.$3);
        t.view.viewInsets = FakeViewPadding(
          bottom: profile.$1.endsWith("keyboard") ? 300 : 0,
        );
        final key = GlobalKey();
        await t.pumpWidget(
          MaterialApp(
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const [Locale('zh')],
            locale: const Locale('zh'),
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff3e899b),
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              fontFamily: 'JarvisPreview',
            ),
            home: RepaintBoundary(
              key: key,
              child: LoginPage(controller: c),
            ),
          ),
        );
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 180)),
        );
        await t.pump(const Duration(milliseconds: 600));
        for (var frame = 0; frame < 25; frame++) {
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(t.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await t.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${output.path}/login-${dark ? 'dark' : 'light'}-${profile.$1}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
