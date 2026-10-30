import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/login_art.dart';

void main() {
  test(
    'Decoded native launch art matches the production first frame over black',
    () async {
      final bytes = await File(
        'android/app/src/main/res/drawable-mdpi/jarvis_launch_reactor.png',
      ).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final native = (await codec.getNextFrame()).image;
      expect(native.width, 288);
      expect(native.height, 288);
      Future<ui.Image> frame(bool bitmap) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(const Color(0xff09090b), BlendMode.src);
        if (bitmap) {
          canvas.drawImage(native, Offset.zero, Paint());
        } else {
          canvas.translate(56, 56);
          ReactorPainter(
            motion: const AlwaysStoppedAnimation(0),
            transition: const AlwaysStoppedAnimation(1),
            mode: ReactorMode.idle,
            dark: true,
            dayBlend: 0,
          ).paint(canvas, const Size(176, 176));
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(288, 288);
        picture.dispose();
        return image;
      }

      final a = await frame(true), b = await frame(false);
      final pa = (await a.toByteData())!.buffer.asUint8List(),
          pb = (await b.toByteData())!.buffer.asUint8List();
      var diff = 0;
      for (var i = 0; i < pa.length; i++) {
        diff += (pa[i] - pb[i]).abs();
      }
      expect(
        diff / pa.length,
        lessThan(.5),
        reason:
            'Native bitmap and live first pose must stay visually identical',
      );
      a.dispose();
      b.dispose();
      native.dispose();
      codec.dispose();
    },
  );
}
