// Render the authored line drawings at actual icon sizes for visual QA.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Render round reactor line icon schemes A B C D', (t) async {
    await t.runAsync(() async {
      final root =
          Platform.environment['JARVIS_REACTOR_ROOT'] ??
          'design/icon/arc-reactor';
      final schemes = jsonDecode(
        await File('$root/schemes.json').readAsString(),
      ) as Map<String, dynamic>;
      for (final entry in schemes.entries) {
        for (final size in [48, 96, 512]) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawColor(Colors.black, BlendMode.src);
          canvas.scale(size / 72);
          canvas.translate(-18, -18);
          for (final p in entry.value['parts'] as List) {
            final paint = Paint()
              ..color = Color(
                int.parse((p['color'] as String).substring(1), radix: 16) |
                    0xff000000,
              )
              ..style = PaintingStyle.stroke
              ..strokeWidth = (p['width'] as num).toDouble()
              ..strokeCap = StrokeCap.round;
            switch (p['type']) {
              case 'polygon':
                final path = Path();
                final points = p['points'] as List;
                for (var i = 0; i < points.length; i++) {
                  final point = points[i] as List;
                  if (i == 0) {
                    path.moveTo(
                      (point[0] as num).toDouble(),
                      (point[1] as num).toDouble(),
                    );
                  } else {
                    path.lineTo(
                      (point[0] as num).toDouble(),
                      (point[1] as num).toDouble(),
                    );
                  }
                }
                path.close();
                canvas.drawPath(path, paint..strokeJoin = StrokeJoin.round);
              case 'circle':
                canvas.drawCircle(
                  const Offset(54, 54),
                  (p['r'] as num).toDouble(),
                  paint,
                );
              case 'line':
                canvas.drawLine(
                  Offset(
                    (p['x1'] as num).toDouble(),
                    (p['y1'] as num).toDouble(),
                  ),
                  Offset(
                    (p['x2'] as num).toDouble(),
                    (p['y2'] as num).toDouble(),
                  ),
                  paint,
                );
              case 'arc':
                canvas.drawArc(
                  Rect.fromCircle(
                    center: const Offset(54, 54),
                    radius: (p['r'] as num).toDouble(),
                  ),
                  (p['start'] as num) * math.pi / 180,
                  ((p['end'] as num) - (p['start'] as num)) * math.pi / 180,
                  false,
                  paint,
                );
            }
          }
          final picture = recorder.endRecording();
          final im = await picture.toImage(size, size);
          final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
          await File('$root/reactor-${entry.key}-$size.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          im.dispose();
          picture.dispose();
        }
      }
    });
  });
}
