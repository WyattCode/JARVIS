import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/action_menu.dart';

const effort = [
  JarvisMenuAction('none', '关闭'),
  JarvisMenuAction('low', '低'),
  JarvisMenuAction('medium', '中'),
  JarvisMenuAction('high', '高'),
];

Widget host({
  required List<JarvisMenuAction> actions,
  required ValueChanged<String> onSelected,
  String? selected,
  bool labelled = true,
  Alignment align = Alignment.bottomLeft,
  bool reduced = false,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: align,
      child: JarvisActionMenu(
        tooltip: '选择思考深度',
        selectedValue: selected,
        actions: actions,
        onSelected: onSelected,
        child: labelled
            ? const SizedBox(
                width: 120,
                height: 36,
                child: Center(child: Text('思考 中')),
              )
            : null,
      ),
    ),
  ),
);

void main() {
  void useWindow(WidgetTester t, [Size size = const Size(400, 800)]) {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDisplayFeatures);
  }

  final panel = find.byKey(const Key('action-menu-panel'));

  testWidgets(
    'Effort menu hangs above its anchor with icons, a pill and a check on the '
    'chosen row',
    (t) async {
      useWindow(t);
      final calls = <MethodCall>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final chosen = <String>[];
      await t.pumpWidget(
        host(
          actions: effort,
          selected: 'medium',
          onSelected: chosen.add,
          align: const Alignment(-.4, .8),
        ),
      );
      final anchor = t.getRect(find.text('思考 中'));
      await t.tap(find.byTooltip('选择思考深度'));
      await t.pump();
      // A medium impact as it opens; the panel grows out of the anchor.
      expect(
        calls
            .where((m) => m.method == 'HapticFeedback.vibrate')
            .map((m) => m.arguments),
        ['HapticFeedbackType.mediumImpact'],
      );
      final first = t.getRect(panel);
      await t.pump(const Duration(milliseconds: 60));
      expect(t.getRect(panel).width, greaterThan(first.width));
      await t.pumpAndSettle();
      expect(JarvisActionMenu.isOpen, true);
      final rect = t.getRect(panel);
      // Above the anchor, 9 clear of it, lined up with its left edge.
      final button = t.getRect(find.byTooltip('选择思考深度'));
      expect(rect.bottom, closeTo(button.top - 9, 1));
      expect(rect.left, closeTo(button.left, 1));
      expect(rect.bottom, lessThan(anchor.top));
      final shape = t.widget<Material>(panel).shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(34));
      // Rows: 17pt, with the effort icons.
      expect(t.widget<Text>(find.text('低')).style?.fontSize, 17);
      expect(find.byIcon(Icons.block), findsOneWidget);
      expect(find.byIcon(Icons.bolt), findsOneWidget);
      expect(find.byIcon(Icons.lightbulb_outline), findsOneWidget);
      expect(find.byIcon(Icons.psychology), findsOneWidget);
      expect(
        t.getSize(find.byKey(const ValueKey('menu-chip-low'))),
        const Size(40, 40),
      );
      // The chosen row: a pill and an accent check; the others have neither.
      expect(find.byIcon(Icons.check), findsOneWidget);
      final icon = t.widget<Icon>(
        find.byKey(const ValueKey('menu-check-medium')),
      );
      expect(icon.color, const Color(0xff137589));
      final pill = t.widget<Material>(
        find
            .ancestor(of: find.text('中'), matching: find.byType(Material))
            .first,
      );
      expect(pill.color!.a, closeTo(.12, .01));
      final plain = t.widget<Material>(
        find
            .ancestor(of: find.text('低'), matching: find.byType(Material))
            .first,
      );
      expect(plain.color, Colors.transparent);
      // Choosing a row runs it and closes the menu.
      await t.tap(find.text('高'));
      await t.pumpAndSettle();
      expect(chosen, ['high']);
      expect(JarvisActionMenu.isOpen, false);
      expect(panel, findsNothing);
    },
  );

  testWidgets('A touch elsewhere closes it; reduced motion opens at once', (
    t,
  ) async {
    useWindow(t);
    await t.pumpWidget(
      host(actions: effort, onSelected: (_) {}, reduced: true),
    );
    await t.tap(find.byTooltip('选择思考深度'));
    await t.pump();
    final size = t.getRect(panel);
    await t.pump(const Duration(milliseconds: 50));
    expect(t.getRect(panel), size);
    await t.tapAt(const Offset(300, 100));
    await t.pumpAndSettle();
    expect(panel, findsNothing);
    expect(JarvisActionMenu.isOpen, false);
  });

  testWidgets(
    'A selected flag marks a row without selectedValue; a bar menu opens '
    'below its button',
    (t) async {
      useWindow(t);
      await t.pumpWidget(
        host(
          labelled: false,
          align: Alignment.topRight,
          actions: const [
            JarvisMenuAction('a', '甲', icon: Icons.tune),
            JarvisMenuAction('b', '乙', selected: true),
          ],
          onSelected: (_) {},
        ),
      );
      await t.tap(find.byTooltip('选择思考深度'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-check-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-check-a')), findsNothing);
      final rect = t.getRect(panel);
      final button = t.getRect(find.byIcon(Icons.more_horiz));
      expect(rect.top, greaterThan(button.bottom));
      expect(rect.right, lessThanOrEqualTo(400 - 8));
      expect(
        (t.widget<Material>(panel).shape! as RoundedRectangleBorder)
            .borderRadius,
        BorderRadius.circular(26),
      );
      // Its icon is its own: no effort icons on a menu that is not the effort
      // one.
      expect(find.byIcon(Icons.tune), findsOneWidget);
      expect(find.byIcon(Icons.block), findsNothing);
      JarvisActionMenu.closeOpen();
      await t.pumpAndSettle();
    },
  );

  testWidgets('On a half-folded display the panel stays on the anchor screen', (
    t,
  ) async {
    useWindow(t, const Size(860, 608));
    t.view.displayFeatures = [
      const ui.DisplayFeature(
        bounds: ui.Rect.fromLTWH(425, 0, 10, 608),
        type: ui.DisplayFeatureType.fold,
        state: ui.DisplayFeatureState.postureHalfOpened,
      ),
    ];
    // An anchor near the crease: the panel is kept on its screen.
    await t.pumpWidget(
      host(
        actions: effort,
        onSelected: (_) {},
        align: const Alignment(-.19, 1),
      ),
    );
    await t.tap(find.byTooltip('选择思考深度'));
    await t.pumpAndSettle();
    expect(t.getRect(panel).right, lessThanOrEqualTo(425));
    JarvisActionMenu.closeOpen();
    await t.pumpAndSettle();
  });
}
