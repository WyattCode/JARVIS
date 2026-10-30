import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';

import 'support.dart';

final _landscape = DuoLayout.fromMap({
  'edge': 'right',
  'width': 951.0,
  'height': 669.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
  'regions': [
    {
      'kind': 'division',
      'active': false,
      'x': 455.5,
      'y': 0.0,
      'w': 40.0,
      'h': 669.0,
    },
    {
      'kind': 'occlusion',
      'active': true,
      'x': 867.0,
      'y': 0.0,
      'w': 84.0,
      'h': 124.0,
    },
  ],
});

Future<JarvisController> open(
  WidgetTester t, {
  Size size = const Size(466, 900),
  DuoLayout layout = DuoLayout.none,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  final c = JarvisController(FakeApi(), MemoryVault());
  await c.initialize();
  await t.pumpWidget(
    DuoLayoutScope(
      layout: ValueNotifier(layout),
      child: MaterialApp(home: SettingsPage(controller: c)),
    ),
  );
  await t.pump(const Duration(milliseconds: 400));
  return c;
}

/// One chip's width: the capsule's inside, split evenly.
double segment(WidgetTester t) =>
    t.getSize(find.byKey(const ValueKey('settings-chip-0'))).width;

Future<void> close(WidgetTester t, JarvisController c) async {
  await t.pumpWidget(const SizedBox());
  c.dispose();
}

void main() {
  testWidgets('theme swatches switch the theme', (t) async {
    final c = await open(t);
    await t.tap(find.byKey(const ValueKey('theme-dark')));
    await t.pump();
    expect(c.theme, 'dark');
    await t.tap(find.byKey(const ValueKey('theme-system')));
    await t.pump();
    expect(c.theme, 'system');
    await close(t, c);
  });

  testWidgets('a picker row opens a menu under it and applies the choice', (
    t,
  ) async {
    final c = await open(t);
    await t.tap(find.text('思考深度'));
    await t.pumpAndSettle();
    await t.tap(find.text('低').last);
    await t.pumpAndSettle();
    expect(c.effort, 'low');
    expect(find.text('低'), findsOneWidget, reason: '当前值显示在行右侧');
    await close(t, c);
  });

  testWidgets('font size slider updates the inline preview', (t) async {
    final c = await open(t);
    TextStyle? previewStyle() => t
        .widget<Text>(
          find.descendant(
            of: find.byKey(const Key('settings-preview')),
            matching: find.byType(Text),
          ),
        )
        .style;
    expect(previewStyle()?.fontSize, 16);
    final slider = find.byKey(const Key('message-font-size'));
    await t.ensureVisible(slider);
    await t.drag(
      find.byKey(const Key('settings-scroll')),
      const Offset(0, 150),
    );
    await t.pump();
    await t.drag(slider, const Offset(400, 0));
    await t.pump();
    expect(previewStyle()?.fontSize, 24);
    await close(t, c);
  });

  testWidgets('chips jump to their section and follow the scroll', (t) async {
    final c = await open(t);
    final scroll = find
        .descendant(
          of: find.byKey(const Key('settings-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    double offset() => t.state<ScrollableState>(scroll).position.pixels;
    expect(offset(), 0);
    await t.tap(find.byKey(const ValueKey('settings-chip-3')));
    await t.pumpAndSettle();
    expect(offset(), greaterThan(0));
    expect(
      t.getTopLeft(find.text('导出会话备份')).dy,
      lessThan(900),
      reason: '数据 section is on screen',
    );
    await t.tap(find.byKey(const ValueKey('settings-chip-0')));
    await t.pumpAndSettle();
    expect(offset(), 0);
    await close(t, c);
  });

  testWidgets(
    'inner landscape: preview left of the fold, controls right of it',
    (t) async {
      final c = await open(t, size: const Size(951, 669), layout: _landscape);
      final preview = t.getRect(find.byKey(const Key('settings-preview')));
      final controls = t.getRect(find.byKey(const Key('settings-scroll')));
      expect(preview.right, lessThanOrEqualTo(455.5));
      expect(preview.top, lessThan(150), reason: '预览贴在左半屏顶部，不居中');
      expect(controls.left, greaterThanOrEqualTo(495.5));
      expect(find.text('预览：你好，我是 JARVIS。'), findsNothing);
      await close(t, c);
    },
  );

  testWidgets(
    'narrow screens keep one column with the preview inside the font card',
    (t) async {
      final c = await open(t);
      expect(find.byKey(const Key('settings-preview')), findsOneWidget);
      final controls = t.getRect(find.byKey(const Key('settings-scroll')));
      expect(controls.left, 0);
      expect(controls.width, 466);
      await close(t, c);
    },
  );

  testWidgets('the chips are a frosted bar whose lower edge fades, no line', (
    t,
  ) async {
    final c = await open(t);
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const Key('settings-chips-bar')),
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.constraints?.maxHeight == .5,
        ),
      ),
      findsNothing,
    );
    // Rows at rest sit clear of the fading edge.
    final top = t.getTopLeft(find.text('外观').last).dy;
    expect(top, greaterThanOrEqualTo(SettingsChips.restInset));
    await close(t, c);
  });

  testWidgets('the chip capsule is as wide as the cards below', (t) async {
    for (final size in const [Size(466, 678), Size(951, 669), Size(375, 812)]) {
      final c = await open(t, size: size);
      final capsule = t.getRect(
        find
            .descendant(
              of: find.byKey(const Key('settings-chips-bar')),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final card = t.getRect(find.byType(SettingsGroup).first);
      expect(capsule.left, closeTo(card.left, .6), reason: '$size');
      expect(capsule.right, closeTo(card.right, .6), reason: '$size');
      await close(t, c);
    }
  });

  testWidgets('Reduce Transparency: the bar is solid', (t) async {
    final c = await open(t, layout: const DuoLayout(reduceTransparency: true));
    expect(find.byType(BackdropFilter), findsNothing);
    await close(t, c);
  });

  testWidgets('the selection capsule slides to the section you jump to', (
    t,
  ) async {
    final c = await open(t);
    double left() => t
        .widget<AnimatedPositioned>(
          find.descendant(
            of: find.byKey(const Key('settings-chips-bar')),
            matching: find.byType(AnimatedPositioned),
          ),
        )
        .left!;
    expect(left(), 0);
    await t.tap(find.byKey(const ValueKey('settings-chip-2')));
    await t.pumpAndSettle();
    expect(left(), segment(t) * 2);
    await close(t, c);
  });

  testWidgets(
    'the chip stays on the tapped section while the page scrolls there',
    (t) async {
      final c = await open(t);
      final chip = find.byKey(const ValueKey('settings-chip-3'));
      await t.tap(chip);
      await t.pump(const Duration(milliseconds: 100));
      double left() => t
          .widget<AnimatedPositioned>(
            find.descendant(
              of: find.byKey(const Key('settings-chips-bar')),
              matching: find.byType(AnimatedPositioned),
            ),
          )
          .left!;
      expect(left(), segment(t) * 3, reason: '不经过中间的标签');
      await t.pumpAndSettle();
      expect(left(), segment(t) * 3);
      await close(t, c);
    },
  );

  testWidgets(
    'a stale landscape report on a narrow page falls back to one column',
    (t) async {
      final c = await open(t, size: const Size(466, 678), layout: _landscape);
      expect(find.byKey(const Key('settings-scroll')), findsOneWidget);
      expect(t.takeException(), isNull);
      final controls = t.getRect(find.byKey(const Key('settings-scroll')));
      expect(controls.left, 0);
      await close(t, c);
    },
  );
}
