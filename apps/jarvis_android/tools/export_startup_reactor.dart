// Native launch art is rendered by the exact production painter, not the
// simplified launcher glyph. 288dp canvas / centered 176dp reactor.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/login_art.dart';

void main() {
  testWidgets('Export native launch artwork from production reactor first frame', (
    t,
  ) async {
    await t.runAsync(() async {
      for (final density in [
        ('mdpi', 1.0),
        ('hdpi', 1.5),
        ('xhdpi', 2.0),
        ('xxhdpi', 3.0),
        ('xxxhdpi', 4.0),
      ]) {
        final size = (288 * density.$2).round();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.scale(density.$2);
        canvas.translate(56, 56);
        ReactorPainter(
          motion: const AlwaysStoppedAnimation(0),
          transition: const AlwaysStoppedAnimation(1),
          mode: ReactorMode.idle,
          dark: true,
          dayBlend: 0,
        ).paint(canvas, const Size(176, 176));
        final picture = recorder.endRecording();
        final image = await picture.toImage(size, size);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          'android/app/src/main/res/drawable-${density.$1}/jarvis_launch_reactor.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        if ([1.0, 2.0, 3.0].contains(density.$2)) {
          await File(
            'design/ios-launch/Assets.xcassets/JarvisLaunchMark.imageset/JarvisLaunchMark@${density.$2.toInt()}x.png',
          ).writeAsBytes(data.buffer.asUint8List());
        }
        image.dispose();
        picture.dispose();
      }
    });
  });
}
