// Preview authored vector marks before choosing a launcher asset.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Path geometry(String input) {
  final tokens = RegExp(r'[MLQCZ]|-?\d+(?:\.\d+)?')
      .allMatches(input)
      .map((x) => x.group(0)!)
      .toList();
  final path = Path();
  var i = 0;
  double next() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    switch (tokens[i++]) {
      case 'M':
        path.moveTo(next(), next());
      case 'L':
        path.lineTo(next(), next());
      case 'Q':
        path.quadraticBezierTo(next(), next(), next(), next());
      case 'C':
        path.cubicTo(next(), next(), next(), next(), next(), next());
      case 'Z':
        path.close();
      default:
        throw FormatException('Unsupported authored path');
    }
  }
  return path;
}

void main() {
  testWidgets('Preview minimal icon candidates from authored vector paths', (
    t,
  ) async {
    await t.runAsync(() async {
      final options = jsonDecode(
        await File('design/icon/minimal/options.json').readAsString(),
      ) as Map<String, dynamic>;
      for (final entry in options.entries) {
        final data = entry.value as Map<String, dynamic>;
        for (final size in [48, 96, 512]) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          final bounds = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
          canvas.clipRRect(
            RRect.fromRectAndRadius(bounds, Radius.circular(size * .23)),
          );
          canvas.drawColor(Colors.black, BlendMode.src);
          canvas.scale(size / 72);
          canvas.translate(-18, -18);
          canvas.translate(54, 54);
          canvas.scale((data['scale'] as num).toDouble());
          canvas.translate(-54, -54);
          for (final item in data['paths'] as List) {
            final color = Color(
              int.parse((item['fill'] as String).substring(1), radix: 16) |
                  0xff000000,
            );
            canvas.drawPath(
              geometry(item['d'] as String),
              Paint()..color = color,
            );
          }
          final picture = recorder.endRecording();
          final image = await picture.toImage(size, size);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('design/icon/minimal/${entry.key}-$size.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        }
      }
    });
  });
}
