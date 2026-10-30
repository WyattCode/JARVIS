// Export the selected authored mark at identical optical scale on every surface.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'minimal_icon_options.dart' show geometry;

void main() {
  testWidgets('Export chosen flat icon and mask previews', (t) async {
    await t.runAsync(() async {
      final key = Platform.environment['JARVIS_ICON_VARIANT'] ?? 'C';
      final options = jsonDecode(
        await File('design/icon/minimal/options.json').readAsString(),
      ) as Map<String, dynamic>;
      final data = options[key] as Map<String, dynamic>;
      final previewOnly = Platform.environment['JARVIS_PREVIEW_ONLY'] == '1';
      if (!previewOnly) {
        String vector({bool legacy = false, bool mono = false}) {
          final extent = legacy ? 72 : 108;
          final out = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n')
            ..writeln(
              '<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="$extent" android:viewportHeight="$extent">',
            );
          if (legacy) {
            out.writeln(
              '<path android:fillColor="#000000" android:pathData="M0,0H72V72H0Z"/>',
            );
            out.writeln(
              '<group android:translateX="-18" android:translateY="-18">',
            );
          }
          final scale = data['scale'];
          out.writeln(
            '<group android:pivotX="54" android:pivotY="54" android:scaleX="$scale" android:scaleY="$scale">',
          );
          for (final path in data['paths'] as List) {
            final color = mono ? '#FFFFFF' : path['fill'];
            final d = path['d'];
            out.writeln(
              '<path android:fillColor="$color" android:pathData="$d"/>',
            );
          }
          out.writeln('</group>');
          if (legacy) {
            out.writeln('</group>');
          }
          out.writeln('</vector>');
          return out.toString();
        }

        const directory = 'android/app/src/main/res/drawable';
        await File('$directory/jarvis_launcher_foreground.xml')
            .writeAsString(vector());
        await File('$directory/jarvis_launcher_legacy.xml')
            .writeAsString(vector(legacy: true));
        await File('$directory/jarvis_launcher_monochrome.xml')
            .writeAsString(vector(mono: true));
        await File('design/icon/minimal/selected.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'variant': key,
            'name': data['name'],
            'background': '#000000',
            'colors': ['#FFFFFF', '#80D7E4'],
            'raster_art_replaced_by_vector': true,
          }),
        );
      }

      Future<void> save(
        int size,
        String file, {
        bool transparent = false,
        String? mask,
        bool monochrome = false,
      }) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final bounds = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
        if (mask == 'circle') {
          canvas.clipPath(Path()..addOval(bounds));
        }
        if (mask == 'rounded') {
          canvas.clipRRect(
            RRect.fromRectAndRadius(bounds, Radius.circular(size * .23)),
          );
        }
        if (!transparent) {
          canvas.drawColor(Colors.black, BlendMode.src);
        }
        // JarvisMark adds 11% tile padding: 72 * .78 = 56.16.
        final extent = transparent ? 56.16 : 72.0;
        canvas.scale(size / extent);
        canvas.translate(-(108 - extent) / 2, -(108 - extent) / 2);
        canvas.translate(54, 54);
        canvas.scale((data['scale'] as num).toDouble());
        canvas.translate(-54, -54);
        for (final path in data['paths'] as List) {
          final color = monochrome
              ? Colors.white
              : Color(
                  int.parse((path['fill'] as String).substring(1), radix: 16) |
                      0xff000000,
                );
          canvas.drawPath(
            geometry(path['d'] as String),
            Paint()..color = color,
          );
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(size, size);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dest = File(file);
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
        image.dispose();
      }

      for (final mask in ['circle', 'rounded']) {
        for (final size in [48, 96, 512]) {
          await save(
            size,
            'design/icon/minimal/$key/$mask-$size.png',
            mask: mask,
          );
        }
      }
      await save(
        512,
        'design/icon/minimal/$key/monochrome.png',
        mask: 'rounded',
        monochrome: true,
      );
      await save(
        512,
        'design/icon/minimal/$key/foreground.png',
        transparent: true,
      );
      if (!previewOnly) {
        await save(512, 'assets/jarvis-icon-night.png', transparent: true);
        for (final density in [
          ('mdpi', 48),
          ('hdpi', 72),
          ('xhdpi', 96),
          ('xxhdpi', 144),
          ('xxxhdpi', 192),
        ]) {
          for (final prefix in ['mipmap', 'mipmap-night']) {
            await save(
              density.$2,
              'android/app/src/main/res/$prefix-${density.$1}/ic_launcher.png',
            );
          }
        }
      }
    });
  });
}
