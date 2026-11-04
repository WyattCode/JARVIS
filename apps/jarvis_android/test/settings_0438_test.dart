import 'dart:ui' show SemanticsValidationResult;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Grouped fields retain semantic name, error, text and stable focused size',
    (t) async {
      final handle = t.ensureSemantics();
      final controller = TextEditingController(text: '42');
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FieldRow(
              label: '回复长度上限（Token）',
              error: '请输入16至32768',
              controller: controller,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      final field = find.byType(TextField);
      final before = t.getSize(field);
      final data = t.getSemantics(field).getSemanticsData();
      expect(data.label, contains('回复长度上限（Token）'));
      expect(data.hint, contains('请输入16至32768'));
      expect(data.validationResult, SemanticsValidationResult.invalid);
      expect(
        t.widget<TextField>(field).decoration!.focusedBorder,
        isA<UnderlineInputBorder>(),
      );
      await t.tap(field);
      await t.pumpAndSettle();
      expect(t.getSize(field), before);
      expect(controller.text, '42');
      expect(t.takeException(), isNull);
      handle.dispose();
      await t.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'Short cover themes are denser while retaining large tap targets',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      for (final size in [const Size(425, 623), const Size(608, 860)]) {
        t.view.physicalSize = size;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ThemeSwatches(value: 'dark', onChanged: (_) {}),
            ),
          ),
        );
        await t.pump();
        final swatch = find.descendant(
          of: find.byKey(const ValueKey('theme-dark')),
          matching: find.byType(AnimatedContainer),
        );
        expect(t.getSize(swatch).height, size.width < 600 ? 56 : 72);
        expect(
          t.getSize(find.byKey(const ValueKey('theme-dark'))).height,
          greaterThanOrEqualTo(44),
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'Fold preview collapse preserves draft, scroll and keyboard focus',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: SettingsPage(controller: c)));
      await t.pump();
      final pane = find.byKey(const Key('settings-preview-pane'));
      expect(t.getSize(pane).width, 344);
      final field = find.descendant(
        of: find.byWidgetPredicate((w) => w is FieldRow && w.label == '助手指令'),
        matching: find.byType(TextField),
      );
      await t.ensureVisible(field);
      await t.pumpAndSettle();
      await t.enterText(field, '保留助手指令');
      await t.pump();
      final before = t.getRect(field).top;
      await t.tap(find.byTooltip('收起实时预览'));
      await t.pumpAndSettle();
      expect(t.getSize(pane).width, 52);
      expect(t.widget<TextField>(field).controller!.text, '保留助手指令');
      expect(t.getRect(field).top, closeTo(before, 16));
      await t.tap(find.byTooltip('展开实时预览'));
      await t.pumpAndSettle();
      expect(t.getSize(pane).width, 344);
      await t.ensureVisible(field);
      await t.tap(field);
      await t.pump();
      t.view.viewInsets = const FakeViewPadding(bottom: 260);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(
        t
            .widget<EditableText>(
              find.descendant(of: field, matching: find.byType(EditableText)),
            )
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(t.widget<TextField>(field).controller!.text, '保留助手指令');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
