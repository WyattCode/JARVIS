import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/login_art.dart';

void main() {
  testWidgets('Export production reactor painter frames', (t) async {
    await t.runAsync(() async {
      final root = Directory('/home/user/.local/state/jarvis-reactor-frames');
      await root.create(recursive: true);
      for (final dark in [true, false]) {
        for (final mode in ReactorMode.values) {
          final count = dark && mode == ReactorMode.idle ? 240 : 1;
          for (var i = 0; i < count; i++) {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            canvas.drawColor(
              dark ? const Color(0xff09090b) : const Color(0xfff4f8fa),
              BlendMode.src,
            );
            ReactorPainter(
              motion: AlwaysStoppedAnimation(i / count),
              transition: const AlwaysStoppedAnimation(1),
              mode: mode,
              dark: dark,
            ).paint(canvas, const Size(320, 256));
            final picture = recorder.endRecording();
            final image = await picture.toImage(320, 256);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '${root.path}/${dark ? 'dark' : 'light'}-${mode.name}-$i.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            picture.dispose();
            image.dispose();
          }
        }
      }
    });
  });
}
