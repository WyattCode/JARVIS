import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/completed_works.dart';
import 'package:jarvis_android/ui/design_tokens.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

import 'c2_support.dart' show sizeWindow;
import 'support.dart';

void main() {
  testWidgets('the works sheet: fixed header, content height, 24 pt corners', (
    t,
  ) async {
    sizeWindow(
      t,
      const Size(402, 874),
      const EdgeInsets.only(top: 62, bottom: 34),
    );
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    c.current.tasks.add(
      MediaTask(
        id: 'a',
        kind: 'video',
        prompt: 'a',
        args: {},
        status: 'completed',
        urls: ['https://example.test/a.mp4'],
      ),
    );
    late BuildContext host;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              host = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    unawaited(showGeneratedWorks(host, c));
    await t.pumpAndSettle();
    expect(find.text('生成作品'), findsOneWidget);
    expect(find.byType(MediaCard), findsOneWidget);
    // One work: the sheet is as high as its content, well under 80% of the window.
    final surface = find.byWidgetPredicate(
      (w) =>
          w is Material &&
          w.shape is RoundedRectangleBorder &&
          (w.shape! as RoundedRectangleBorder).side.width == .5,
    );
    final sheet = t.getRect(surface);
    expect(sheet.height, lessThan(874 * .8));
    final material = t.widget<Material>(surface);
    final shape = material.shape! as RoundedRectangleBorder;
    expect(
      shape.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    );
    expect(shape.side.width, .5);
    // Content starts 20 pt in from the sheet's edge.
    expect(t.getRect(find.byType(MediaCard)).left - sheet.left, 20);
    // 完成 closes it.
    await t.tap(find.byKey(const Key('works-done')));
    await t.pumpAndSettle();
    expect(find.text('生成作品'), findsNothing);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
