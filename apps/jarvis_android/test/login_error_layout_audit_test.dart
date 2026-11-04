import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Long login error fits above unchanged fields across fold windows and text scales',
    (t) async {
      await t.runAsync(() async {
        final path = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
        if (await File(path).exists()) {
          final f = FontLoader('Roboto')
            ..addFont(
              Future.value(
                ByteData.sublistView(await File(path).readAsBytes()),
              ),
            );
          await f.load();
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
      for (final size in [
        const Size(425, 623),
        const Size(608, 860),
        const Size(860, 608),
      ]) {
        for (final scale in [1.0, 1.3, 1.5]) {
          for (final ime in [0.0, 284.0, 320.0]) {
            t.view.physicalSize = size;
            t.view.viewPadding = const FakeViewPadding(top: 46, bottom: 20);
            t.view.padding = FakeViewPadding(top: 46, bottom: ime > 0 ? 0 : 20);
            t.view.viewInsets = FakeViewPadding(bottom: ime);
            final c = JarvisController(FakeApi(), MemoryVault());
            c.error = '暂时无法连接服务器，请检查网络连接并稍后重试。如果问题仍然存在，请检查服务地址和账号状态。';
            await t.pumpWidget(
              MaterialApp(
                theme: theme,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: LoginPage(controller: c),
              ),
            );
            await t.pump();
            await t.pump(const Duration(milliseconds: 500));
            expect(
              t.takeException(),
              isNull,
              reason: '$size text=$scale keyboard=$ime',
            );
            if (size.width == 425) {
              final submit = find.widgetWithText(FilledButton, '登录');
              expect(
                t.getRect(submit).bottom,
                lessThanOrEqualTo(size.height - (ime > 0 ? ime : 20) - 24 + .1),
                reason:
                    'Submit must remain above keyboard with its bottom margin',
              );
            }
            await t.pumpWidget(const SizedBox());
            c.dispose();
          }
        }
      }
    },
  );
}
