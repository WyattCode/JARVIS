import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Data section starts below navigation on short cover and unfolded windows',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      for (final size in [
        const Size(425, 623),
        const Size(608, 860),
        const Size(860, 608),
      ]) {
        t.view.physicalSize = size;
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await t.pumpWidget(MaterialApp(home: SettingsPage(controller: c)));
        await t.pump();
        await t.tap(find.byKey(const ValueKey('settings-chip-3')));
        await t.pumpAndSettle();
        final section = find.byWidgetPredicate(
          (w) => w is SettingsSection && w.title == '数据',
        );
        final title = find.descendant(of: section, matching: find.text('数据'));
        final viewport = t.getRect(find.byKey(const Key('settings-scroll')));
        expect(
          t.getRect(title).top,
          inInclusiveRange(viewport.top, viewport.top + 40),
        );
        expect(find.text('API 密钥（可选）'), findsNothing);
        expect(find.text('服务地址'), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
  testWidgets(
    'Token error has matching underline and reveals label input and error above IME',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(608, 860);
      t.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: SettingsPage(controller: c)));
      await t.pump();
      final row = find.byWidgetPredicate(
        (w) => w is FieldRow && w.label == '回复长度上限（Token）',
      );
      final field = find.descendant(of: row, matching: find.byType(TextField));
      await t.ensureVisible(field);
      await t.pumpAndSettle();
      await t.enterText(field, '1');
      await t.pumpAndSettle();
      final viewport = t.getRect(find.byKey(const Key('settings-scroll'))),
          rect = t.getRect(row);
      expect(rect.top, greaterThanOrEqualTo(viewport.top));
      expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
      final colors = Theme.of(t.element(field)).colorScheme;
      expect(
        t.widget<TextField>(field).decoration!.focusedBorder!.borderSide.color,
        colors.error,
      );
      expect(find.text('请输入16至32768，或留空'), findsOneWidget);
      expect(c.settings.maxTokens, 0);
      await t.enterText(field, '1024');
      await t.pumpAndSettle();
      expect(c.settings.maxTokens, 1024);
      expect(find.text('请输入16至32768，或留空'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets('Collapsed preview exposes a distinct 44dp filled panel button', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(860, 608);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(MaterialApp(home: SettingsPage(controller: c)));
    await t.pump();
    await t.tap(find.byTooltip('收起实时预览'));
    await t.pumpAndSettle();
    final button = find.byTooltip('展开实时预览');
    expect(t.getSize(button).width, greaterThanOrEqualTo(44));
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
    expect(
      t
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '展开实时预览',
            ),
          )
          .style,
      isNotNull,
    );
    await t.tap(button);
    await t.pumpAndSettle();
    expect(find.byTooltip('收起实时预览'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
