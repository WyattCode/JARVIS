// Export actual icon resources and clearly labelled platform-effect simulations.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Path shape(Map<String, dynamic> p) {
  final path = Path();
  switch (p['type']) {
    case 'circle':
      path.addOval(
        Rect.fromCircle(
          center: const Offset(54, 54),
          radius: (p['r'] as num).toDouble(),
        ),
      );
    case 'line':
      path.moveTo((p['x1'] as num).toDouble(), (p['y1'] as num).toDouble());
      path.lineTo((p['x2'] as num).toDouble(), (p['y2'] as num).toDouble());
    case 'polygon':
      final points = p['points'] as List;
      for (var i = 0; i < points.length; i++) {
        final q = points[i] as List;
        if (i == 0) {
          path.moveTo((q[0] as num).toDouble(), (q[1] as num).toDouble());
        } else {
          path.lineTo((q[0] as num).toDouble(), (q[1] as num).toDouble());
        }
      }
      path.close();
    case 'arc':
      path.addArc(
        Rect.fromCircle(
          center: const Offset(54, 54),
          radius: (p['r'] as num).toDouble(),
        ),
        (p['start'] as num) * math.pi / 180,
        ((p['end'] as num) - (p['start'] as num)) * math.pi / 180,
      );
  }
  return path;
}

Color colorOf(String value) =>
    Color(int.parse(value.substring(1), radix: 16) | 0xff000000);
void glyph(
  Canvas canvas,
  List<dynamic> parts,
  double size, {
  double extent = 108,
  double scale = 1,
  String layer = 'all',
  bool material = false,
  bool monochrome = false,
  bool optical = false,
  Color? override,
}) {
  canvas.save();
  canvas.translate(size / 2, size / 2);
  canvas.scale(size / extent * scale);
  canvas.translate(-54, -54);
  for (final raw in parts) {
    final p = Map<String, dynamic>.from(raw as Map);
    final core = p['color'] == '#8FDCEB';
    if (layer == 'structure' && core || layer == 'core' && !core) {
      continue;
    }
    final path = shape(p);
    var width = (p['width'] as num).toDouble();
    if (optical) {
      width = math.max(width, extent / size * .85 / scale);
    }
    final color =
        override ?? (monochrome ? Colors.white : colorOf(p['color'] as String));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    if (material) {
      canvas.drawPath(
        path.shift(const Offset(0, .22)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width + .25
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.black.withValues(alpha: .65)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, .3),
      );
      paint.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: core
            ? const [Color(0xffd8fcff), Color(0xff90dceb), Color(0xff65aabe)]
            : const [Color(0xffffffff), Color(0xffe8f2f8), Color(0xffbccbd8)],
      ).createShader(const Rect.fromLTWH(24, 24, 60, 60));
    }
    canvas.drawPath(path, paint);
  }
  canvas.restore();
}

void plate(Canvas canvas, double size, {bool legacy = false}) {
  final inset = size * (legacy ? .0625 : .018);
  final bounds = Rect.fromLTWH(
    inset,
    inset,
    size - 2 * inset,
    size - 2 * inset,
  );
  final radius = (size - 2 * inset) * .225;
  final path = Path()
    ..addRRect(RRect.fromRectAndRadius(bounds, Radius.circular(radius)));
  canvas.drawShadow(
    path,
    Colors.black.withValues(alpha: .65),
    size * .016,
    true,
  );
  canvas.drawPath(
    path,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xff1d2731), Color(0xff090e14), Color(0xff020405)],
        stops: [0, .34, 1],
      ).createShader(bounds),
  );
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size / 600
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: .38),
          Colors.white.withValues(alpha: .04),
          Colors.white.withValues(alpha: .14),
        ],
      ).createShader(bounds),
  );
  final inner = bounds.deflate(size * .008);
  canvas.drawRRect(
    RRect.fromRectAndRadius(inner, Radius.circular(radius - size * .008)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size / 1100
      ..color = Colors.white.withValues(alpha: .045),
  );
}

void main() {
  testWidgets('Export selected platform icon layers, dimensions and previews', (
    t,
  ) async {
    await t.runAsync(() async {
      const root = 'design/icon/platform-candidates';
      final selections = jsonDecode(
        await File('$root/selection.json').readAsString(),
      ) as Map<String, dynamic>;
      for (final entry in selections.entries) {
        final item = entry.value as Map<String, dynamic>;
        final parts = item['parts'] as List;
        final name = item['name'] as String;
        Future<void> save(
          String file,
          int size,
          String kind, {
          String layer = 'all',
        }) async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          switch (kind) {
            case 'layer':
              glyph(canvas, parts, size.toDouble(), scale: 1.18, layer: layer);
            case 'android-foreground':
              glyph(canvas, parts, size.toDouble());
            case 'android-mono':
              glyph(canvas, parts, size.toDouble(), monochrome: true);
            case 'square':
              canvas.drawColor(Colors.black, BlendMode.src);
              glyph(canvas, parts, size.toDouble(), extent: 72);
            case 'android-rounded':
            case 'android-circle':
            case 'themed':
              final box = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
              final mask = kind == 'android-circle'
                  ? (Path()..addOval(box))
                  : (Path()..addRRect(
                      RRect.fromRectAndRadius(box, Radius.circular(size * .23)),
                    ));
              canvas.clipPath(mask);
              canvas.drawColor(
                kind == 'themed' ? const Color(0xffd1e5eb) : Colors.black,
                BlendMode.src,
              );
              glyph(
                canvas,
                parts,
                size.toDouble(),
                extent: 72,
                override: kind == 'themed' ? const Color(0xff203e49) : null,
              );
            case 'macos':
            case 'compat':
              final legacy = kind == 'compat';
              plate(canvas, size.toDouble(), legacy: legacy);
              glyph(
                canvas,
                parts,
                size.toDouble(),
                scale: legacy ? 1.05 : 1.18,
                material: true,
                optical: true,
              );
          }
          final picture = recorder.endRecording();
          final image = await picture.toImage(size, size);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final dest = File('$root/${entry.key}/$file');
          await dest.parent.create(recursive: true);
          await dest.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        }

        for (final layer in ['structure', 'core']) {
          await save(
            'macos/layers/$layer-1024.png',
            1024,
            'layer',
            layer: layer,
          );
          await save(
            'macos/$name.icon/Assets/${layer == 'structure' ? '01-Structure' : '02-Core'}.png',
            1024,
            'layer',
            layer: layer,
          );
        }
        await save('android/foreground-432.png', 432, 'android-foreground');
        await save('android/monochrome-432.png', 432, 'android-mono');
        await save('android/play-store-512.png', 512, 'square');
        for (final density in [
          ('mdpi', 48),
          ('hdpi', 72),
          ('xhdpi', 96),
          ('xxhdpi', 144),
          ('xxxhdpi', 192),
        ]) {
          await save(
            'android/res/mipmap-${density.$1}/ic_launcher.png',
            density.$2,
            'android-rounded',
          );
        }
        for (final size in [48, 96, 128, 512, 1024]) {
          await save('preview/macos-$size.png', size, 'macos');
          await save(
            'preview/android-rounded-$size.png',
            size,
            'android-rounded',
          );
          await save(
            'preview/android-circle-$size.png',
            size,
            'android-circle',
          );
        }
        await save('preview/android-themed-512.png', 512, 'themed');
        for (final slot in [
          (16, 1),
          (16, 2),
          (32, 1),
          (32, 2),
          (128, 1),
          (128, 2),
          (256, 1),
          (256, 2),
          (512, 1),
          (512, 2),
        ]) {
          final file =
              'icon_${slot.$1}x${slot.$1}${slot.$2 == 2 ? '@2x' : ''}.png';
          await save(
            'macos/compatibility/$name.iconset/$file',
            slot.$1 * slot.$2,
            'compat',
          );
        }
      }
    });
  });
}
