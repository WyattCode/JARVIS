import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/action_menu.dart';

import '../test/support.dart';

void main() {
  testWidgets('Audit composer geometry, large text and actual menu anchors', (
    t,
  ) async {
    final out = Directory(
      Platform.environment['JARVIS_AUDIT_DIR'] ??
          '/home/user/.local/state/jarvis-android-042-review/controls',
    )..createSync(recursive: true);
    await t.runAsync(() async {
      for (final f in [
        ('Roboto', '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'),
        (
          'MaterialIcons',
          '/home/user/.local/opt/jarvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ),
      ]) {
        final font = FontLoader(f.$1)
          ..addFont(
            Future.value(ByteData.sublistView(await File(f.$2).readAsBytes())),
          );
        await font.load();
      }
    });
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetViewPadding);
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewInsets);
    final seed = JarvisController(FakeApi(), MemoryVault());
    await t.pumpWidget(JarvisApp(controller: seed));
    await t.pump();
    final theme = t.widget<MaterialApp>(find.byType(MaterialApp)).darkTheme!;
    await t.pumpWidget(const SizedBox());
    final results = <Map<String, dynamic>>[];
    for (final size in [
      const Size(320, 568),
      const Size(360, 540),
      const Size(400, 869),
      const Size(425, 623),
      const Size(608, 860),
      const Size(860, 608),
    ]) {
      for (final scale in [1.0, 1.5, 2.0, 2.5]) {
        for (final keyboard in [0.0, 250.0]) {
          for (final draft in ['', '测试草稿']) {
            t.view.physicalSize = size;
            t.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
            t.view.padding = FakeViewPadding(
              top: 24,
              bottom: keyboard == 0 ? 24 : 0,
            );
            t.view.viewInsets = FakeViewPadding(bottom: keyboard);
            final c = JarvisController(FakeApi(), MemoryVault());
            await c.initialize();
            await c.login('Audit', 'test');
            c.setDraft(draft);
            final key = GlobalKey();
            await t.pumpWidget(
              RepaintBoundary(
                key: key,
                child: MaterialApp(
                  theme: theme,
                  debugShowCheckedModeBanner: false,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      disableAnimations: true,
                      textScaler: TextScaler.linear(scale),
                    ),
                    child: child!,
                  ),
                  home: JarvisHome(controller: c),
                ),
              ),
            );
            await t.pump(const Duration(milliseconds: 400));
            if (size.width == 860) {
              await t.runAsync(
                () => precacheImage(
                  const ResizeImage(
                    AssetImage('assets/jarvis-icon-night.png'),
                    width: 32,
                  ),
                  t.element(find.byType(JarvisHome)),
                ),
              );
              await t.pump();
            }
            final errors = <String>[];
            Object? error;
            while ((error = t.takeException()) != null) {
              errors.add(error.toString());
            }
            final composer = t.getRect(find.byType(Composer)),
                frame = t.getRect(find.byKey(const Key('composer-frame')));
            final menu = find.byWidgetPredicate(
              (w) => w is JarvisActionMenu && w.tooltip == '选择思考深度',
            );
            final button = t.getRect(
              find.descendant(of: menu, matching: find.byType(InkWell)).first,
            );
            final row = {
              'size': '${size.width.toInt()}x${size.height.toInt()}',
              'scale': scale,
              'keyboard': keyboard,
              'draft': draft.isNotEmpty,
              'errors': errors,
              'gaps': [
                frame.left - composer.left,
                composer.right - frame.right,
                composer.bottom - frame.bottom,
              ],
              'menu_width': button.width,
            };
            results.add(row);
            if (errors.isNotEmpty ||
                (scale == 1 && keyboard == 0 && draft.isEmpty)) {
              await t.runAsync(() async {
                final image =
                    await (key.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage();
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                File(
                  '${out.path}/${size.width.toInt()}x${size.height.toInt()}-${(scale * 100).round()}-${keyboard.round()}-${draft.isNotEmpty}.png',
                ).writeAsBytesSync(data!.buffer.asUint8List());
                image.dispose();
              });
            }
            if (scale == 1 && keyboard == 0 && draft.isNotEmpty) {
              if (button.right + 12 < frame.right - 100) {
                await t.tapAt(Offset(button.right + 12, button.center.dy));
                await t.pump();
                expect(
                  JarvisActionMenu.isOpen,
                  false,
                  reason: 'blank space must not open reasoning menu',
                );
              }
              await t.tap(menu);
              await t.pump();
              await t.tap(find.text('低').last);
              await t.pump();
              expect(c.effort, 'low');
              expect(c.current.draft, draft);
              row['menu_tap_and_selection'] = true;
            }
            if (scale == 1 &&
                keyboard == 0 &&
                draft.isEmpty &&
                size.width <= 360) {
              await t.ensureVisible(find.byKey(const ValueKey('starter-3')));
              await t.pump();
              final card = t.getRect(find.byKey(const ValueKey('starter-3'))),
                  pane = t.getRect(find.byType(ChatPanel));
              expect(card.bottom, lessThanOrEqualTo(pane.bottom + .1));
              row['last_suggestion_reachable'] = true;
            }
            await t.pumpWidget(const SizedBox());
            c.dispose();
          }
        }
      }
    }
    File('${out.path}/metrics.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
    expect(
      results.where((r) => (r['errors'] as List).isNotEmpty).toList(),
      isEmpty,
    );
    expect(
      results.every(
        (r) => (r['gaps'] as List<double>).every((g) => (g - 10).abs() < .1),
      ),
      true,
    );
  });
}
