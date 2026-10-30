import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

void main() {
  testWidgets('Conversation background scrolls with its label and menu', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(860, 608);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    c.conversations.clear();
    for (var i = 0; i < 30; i++) {
      c.conversations.add(Conversation('row-$i', title: '会话 $i'));
    }
    c.selectedId = 'row-3';
    c.current.messages.add(ChatMessage('assistant', '滚动验证'));
    const background = Color(0xff151515), selected = Color(0xff323230);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme:
              ColorScheme.fromSeed(
                seedColor: Colors.blue,
                brightness: Brightness.dark,
              ).copyWith(
                surface: background,
                surfaceContainerLow: background,
                surfaceContainerHigh: selected,
              ),
          scaffoldBackgroundColor: background,
        ),
        home: RepaintBoundary(
          key: const Key('scroll-canvas'),
          child: JarvisHome(controller: c),
        ),
      ),
    );
    await t.pump();
    final tile = find.ancestor(
      of: find.text('会话 3'),
      matching: find.byType(ListTile),
    );
    final before = t.getRect(tile);
    final paintedSurface = find
        .ancestor(of: tile, matching: find.byType(Material))
        .first;
    expect(
      t.getRect(paintedSurface),
      before,
      reason: '会话背景必须由随行移动的表面绘制，不能画在整块侧栏上',
    );
    final oldPoint = Offset(before.left + 6, before.center.dy);
    final drag = await t.startGesture(const Offset(180, 450));
    await drag.moveBy(const Offset(0, -25));
    await t.pump();
    await drag.moveBy(const Offset(0, -64));
    await t.pump();
    final after = t.getRect(tile);
    expect(after.top, lessThan(before.top - 40));
    final newPoint = Offset(after.left + 6, after.center.dy);
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('scroll-canvas')),
    );
    final pixels = await t.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      Color pixel(Offset p) {
        final n = (p.dy.floor() * image.width + p.dx.floor()) * 4;
        return Color.fromARGB(
          data.getUint8(n + 3),
          data.getUint8(n),
          data.getUint8(n + 1),
          data.getUint8(n + 2),
        );
      }

      final colors = [pixel(newPoint), pixel(oldPoint)];
      image.dispose();
      return colors;
    });
    expect(pixels![0], selected, reason: '选中背景必须跟随文字移动');
    expect(pixels[1], background, reason: '原位置不能留下选中背景');
    await drag.cancel();
    final list = find.byType(ListView).first;
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    t.state<ScrollableState>(scrollable).position.jumpTo(0);
    await t.pump(const Duration(milliseconds: 500));
    final rest = t.getRect(tile);
    final pull = await t.startGesture(const Offset(180, 350));
    await pull.moveBy(const Offset(0, 25));
    await t.pump();
    await pull.moveBy(const Offset(0, 250));
    await t.pump(const Duration(milliseconds: 100));
    final stretched = t.getRect(tile);
    // Overscroll stretches the scrollable's paint transform, not its ancestor Material.
    expect(stretched.top, greaterThan(rest.top + 2));
    final stretchPixel = await t.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final n =
          ((stretched.bottom - 2).floor() * image.width +
              (stretched.left + 20).floor()) *
          4;
      final color = Color.fromARGB(
        data.getUint8(n + 3),
        data.getUint8(n),
        data.getUint8(n + 1),
        data.getUint8(n + 2),
      );
      image.dispose();
      return color;
    });
    expect(stretchPixel, selected, reason: '回弹时背景也必须与整个会话项一起伸缩移动');
    await pull.cancel();
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
