import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

void main() {
  Future<ThemeData> theme(WidgetTester t) async {
    // Load a real CJK font where available; keep the suite runnable on macOS/CI.
    await t.runAsync(() async {
      final candidates = [
        Platform.environment['JARVIS_TEST_CJK_FONT'],
        '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
        '/System/Library/Fonts/PingFang.ttc',
        '/System/Library/Fonts/Language Support/PingFang.ttc',
      ];
      for (final path in candidates) {
        if (path == null || !await File(path).exists()) continue;
        final loader = FontLoader('Roboto')
          ..addFont(
            Future.value(ByteData.sublistView(await File(path).readAsBytes())),
          );
        await loader.load();
        break;
      }
    });
    final c = JarvisController(FakeApi(), MemoryVault());
    await t.pumpWidget(JarvisApp(controller: c));
    await t.pump();
    final result = t.widget<MaterialApp>(find.byType(MaterialApp)).darkTheme!;
    await t.pumpWidget(const SizedBox());
    return result;
  }

  void viewport(WidgetTester t) {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(425, 623);
    t.view.viewPadding = const FakeViewPadding(top: 46, bottom: 20);
    t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetViewPadding);
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewInsets);
  }

  testWidgets(
    'Fold outer: all four suggestions fit above composer without scrolling with real font and system bars',
    (t) async {
      final skin = await theme(t);
      viewport(t);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        MaterialApp(
          theme: skin,
          home: JarvisHome(controller: c),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      final top = t.getRect(find.byType(Composer)).top;
      for (var i = 0; i < 4; i++) {
        final card = find.byKey(ValueKey('starter-$i'));
        expect(
          t.getRect(card).bottom,
          lessThanOrEqualTo(top - 2),
          reason: 'card $i must be fully visible',
        );
        expect(t.getRect(card).top, greaterThan(102));
      }
      final scroll = Scrollable.maybeOf(
        t.element(find.byKey(const ValueKey('starter-0'))),
      )?.position;
      expect(scroll?.maxScrollExtent ?? 0, lessThanOrEqualTo(.5));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Fold outer: full login form and submit fit with keyboard closed and open',
    (t) async {
      final skin = await theme(t);
      viewport(t);
      final c = JarvisController(FakeApi(), MemoryVault());
      await t.pumpWidget(
        MaterialApp(
          theme: skin,
          home: LoginPage(controller: c),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), 'test');
      await t.enterText(fields.at(1), 'not-real');
      expect(
        t.getRect(find.byKey(const ValueKey('login-brand-row'))).top,
        closeTo(58, .1),
      );
      expect(
        t.getSize(find.byKey(const ValueKey('login-reactor-size'))).height,
        greaterThan(130),
      );
      final fieldSize = t.getSize(fields.first);
      for (final ime in [0.0, 284.0, 320.0]) {
        t.view.viewInsets = FakeViewPadding(bottom: ime);
        t.view.padding = FakeViewPadding(top: 46, bottom: ime > 0 ? 0 : 20);
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        final button = find.widgetWithText(FilledButton, '登录');
        expect(
          t.getRect(button).bottom,
          lessThanOrEqualTo(623 - (ime > 0 ? ime : 20)),
          reason: 'submit visible with IME=$ime',
        );
        expect(
          t.getSize(fields.first),
          fieldSize,
          reason: 'IME must not shrink account field',
        );
        expect(
          t.getSize(fields.at(1)).height,
          fieldSize.height,
          reason: 'Password keeps the same field height',
        );
        final formSide = t.getRect(fields.at(0)).left;
        expect(
          623 - (ime > 0 ? ime : 20) - t.getRect(button).bottom,
          closeTo(formSide, .1),
        );
        expect(t.getRect(fields.at(0)).top, greaterThanOrEqualTo(46));
        expect(
          t.getRect(fields.at(1)).bottom,
          lessThanOrEqualTo(t.getRect(button).top),
        );
        final scroll = Scrollable.of(t.element(fields.at(0))).position;
        expect(
          scroll.maxScrollExtent,
          lessThanOrEqualTo(.5),
          reason: 'form should not require scrolling at default scale',
        );
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Fold inner portrait and landscape keep every starter visible with real font and bars',
    (t) async {
      final skin = await theme(t);
      viewport(t);
      for (final size in [const Size(608, 860), const Size(860, 608)]) {
        t.view.physicalSize = size;
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await t.pumpWidget(
          MaterialApp(
            theme: skin,
            home: JarvisHome(controller: c),
          ),
        );
        await t.pump();
        for (final collapsed in [false, true]) {
          if (collapsed && size.width > size.height) {
            await t.tap(find.byTooltip('收起会话'));
            await t.pump();
            await t.pump(const Duration(milliseconds: 400));
          }
          final composer = t.getRect(find.byType(Composer));
          for (var i = 0; i < 4; i++) {
            final rect = t.getRect(find.byKey(ValueKey('starter-$i')));
            expect(
              rect.bottom,
              lessThanOrEqualTo(composer.top - 2),
              reason: '$size / $collapsed / $i',
            );
          }
          expect(t.takeException(), isNull);
        }
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
  testWidgets(
    'Fold inner login fits in portrait and landscape without scrolling',
    (t) async {
      final skin = await theme(t);
      viewport(t);
      for (final size in [const Size(608, 860), const Size(860, 608)]) {
        t.view.physicalSize = size;
        final c = JarvisController(FakeApi(), MemoryVault());
        await t.pumpWidget(
          MaterialApp(
            theme: skin,
            home: LoginPage(controller: c),
          ),
        );
        await t.pump();
        final submit = find.widgetWithText(FilledButton, '登录');
        for (final ime in [0.0, 284.0, 320.0]) {
          t.view.viewInsets = FakeViewPadding(bottom: ime);
          t.view.padding = FakeViewPadding(top: 46, bottom: ime > 0 ? 0 : 20);
          await t.pump();
          await t.pump(const Duration(milliseconds: 500));
          expect(
            t.getRect(submit).bottom,
            lessThanOrEqualTo(size.height - (ime > 0 ? ime : 20)),
            reason: '$size/IME=$ime',
          );
          if (size.width > size.height && ime == 0) {
            expect(
              t.getRect(find.byKey(const ValueKey('login-brand-row'))).top,
              closeTo(46 + 20, .1),
            );
          }
          final scroll = Scrollable.of(t.element(find.byType(TextField).first))
              .position;
          expect(
            scroll.maxScrollExtent,
            lessThanOrEqualTo(.5),
            reason: '$size/IME=$ime',
          );
        }
        t.view.resetViewInsets();
        t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
}
