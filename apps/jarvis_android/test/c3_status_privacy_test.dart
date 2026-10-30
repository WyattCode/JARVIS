import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/privacy_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';
import 'package:jarvis_android/ui/status_page.dart';

import 'c2_support.dart';
import 'c3_support.dart';
import 'support.dart';

class QueueStatusApi extends FakeApi {
  final pending = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> toolsStatus() {
    final c = Completer<Map<String, dynamic>>();
    pending.add(c);
    return c.future;
  }
}

Map<String, dynamic> status(List<(String, String)> rows) => {
  'mem_available_bytes': 8 * 1073741824,
  'data': [
    for (final (name, state) in rows) {'name': name, 'state': state},
  ],
};

DuoLayout layoutFor(Pose pose) => switch (pose.name) {
  'outer' => outerDisplay,
  'inner landscape' => flatLandscape,
  _ => DuoLayout.none,
};

Future<(JarvisController, QueueStatusApi)> pumpStatus3(
  WidgetTester t, {
  Pose? pose,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final p =
      pose ??
      const Pose(
        'Pro portrait',
        Size(402, 874),
        EdgeInsets.only(top: 62, bottom: 34),
      );
  sizeWindow(t, p.size, p.insets);
  final api = QueueStatusApi();
  final c = JarvisController(api, MemoryVault());
  await c.initialize();
  addTearDown(c.dispose);
  await t.pumpWidget(
    withLayout(
      layoutFor(p),
      appHost(
        StatusPage(controller: c),
        scale: scale,
        brightness: brightness,
      ),
    ),
  );
  await t.pump();
  return (c, api);
}

void main() {
  group('status page', () {
    testWidgets('says when it was read', (t) async {
      final (_, api) = await pumpStatus3(t);
      expect(find.textContaining('更新于'), findsNothing);
      api.pending.single.complete(status([('语音', 'ready')]));
      await t.pump();
      await t.pump();
      expect(find.textContaining(RegExp(r'更新于 \d\d:\d\d')), findsOneWidget);
    });

    testWidgets('an empty list has its own state', (t) async {
      final (_, api) = await pumpStatus3(t);
      api.pending.single.complete(status([]));
      await t.pump();
      await t.pump();
      expect(find.text('服务暂未返回模型状态'), findsOneWidget);
      // The refresh button is in the app bar or in the Duo rail: the hint does not say where.
      expect(find.textContaining('点刷新重试'), findsOneWidget);
      expect(find.textContaining('右上角'), findsNothing);
      expect(find.byType(SettingsGroup), findsNothing);
    });

    testWidgets('descriptions use the neutral text colour', (t) async {
      final (_, api) = await pumpStatus3(t);
      api.pending.single.complete(status([('语音', 'ready')]));
      await t.pump();
      await t.pump();
      final scheme = Theme.of(t.element(find.byType(StatusPage))).colorScheme;
      final text = t.widget<Text>(find.textContaining('语音、图片和视频模型可以按需加载'));
      expect(text.style?.color, scheme.onSurfaceVariant);
    });

    testWidgets('pulling down refreshes, with one indicator', (t) async {
      final (_, api) = await pumpStatus3(t);
      api.pending.single.complete(status([('语音', 'ready')]));
      await t.pump();
      await t.pump();
      await t.fling(find.byType(ListView), const Offset(0, 400), 1000);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(api.pending.length, 2, reason: 'a second request was made');
      expect(find.byType(LinearProgressIndicator), findsNothing);
      api.pending.last.complete(status([('语音', 'busy')]));
      await t.pumpAndSettle();
      expect(find.text('正在处理'), findsOneWidget);
    });

    testWidgets('spinner and bar carry labels for VoiceOver', (t) async {
      final semantics = t.ensureSemantics();
      final (_, api) = await pumpStatus3(t);
      expect(find.bySemanticsLabel('正在读取模型状态'), findsOneWidget);
      api.pending.single.complete(status([('语音', 'ready')]));
      await t.pump();
      await t.pump();
      // The list stays while a refresh runs; the thin bar names itself.
      await t.tap(find.byTooltip('刷新状态'));
      await t.pump();
      expect(find.bySemanticsLabel('正在刷新模型状态'), findsOneWidget);
      semantics.dispose();
    });

    final poses = [...straightPoses, ...foldPoses];
    for (final pose in poses) {
      for (final scale in textScales) {
        for (final brightness in Brightness.values) {
          testWidgets('${pose.name} x$scale ${brightness.name}', (t) async {
            final (_, api) = await pumpStatus3(
              t,
              pose: pose,
              scale: scale,
              brightness: brightness,
            );
            api.pending.single.complete(
              status([for (var i = 0; i < 12; i++) ('一个相当长的模型名称 $i', 'ready')]),
            );
            await t.pump();
            await t.pump();
            expect(t.takeException(), isNull);
            final safe = pose.safe;
            for (final group in find.byType(SettingsGroup).evaluate()) {
              final r = t.getRect(find.byWidget(group.widget));
              expect(r.left, greaterThanOrEqualTo(safe.left - .5));
              expect(r.right, lessThanOrEqualTo(safe.right + .5));
            }
            final text = t.getRect(find.textContaining('更新于'));
            expect(text.left, greaterThanOrEqualTo(safe.left - .5));
            expect(text.right, lessThanOrEqualTo(safe.right + .5));
          });
        }
      }
    }
  });

  group('privacy page', () {
    Future<JarvisController> pumpPrivacy(
      WidgetTester t,
      Pose pose,
      double scale,
      Brightness brightness,
    ) async {
      sizeWindow(t, pose.size, pose.insets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        withLayout(
          layoutFor(pose),
          appHost(
            PrivacyPage(controller: c),
            scale: scale,
            brightness: brightness,
          ),
        ),
      );
      await t.pump();
      return c;
    }

    testWidgets(
      'names the server and the AI, shows the support row, hides the empty policy row',
      (t) async {
        final c = await pumpPrivacy(t, straightPoses[2], 1, Brightness.light);
        final scroll = find.byKey(const Key('privacy-scroll'));
        await t.drag(scroll, const Offset(0, -300));
        expect(find.textContaining('https://jarvis.example.com'), findsOneWidget);
        expect(find.textContaining('人工智能生成'), findsOneWidget);
        // The open-source build sets neither a policy url nor a support address: no dead link rows.
        expect(PrivacyLinks.privacyPolicyUrl, isEmpty);
        expect(find.text('隐私政策'), findsNothing);
        expect(find.text('联系支持'), findsNothing);
        c.dispose();
      },
    );

    final poses = [...straightPoses, ...foldPoses];
    for (final pose in poses) {
      for (final scale in textScales) {
        for (final brightness in Brightness.values) {
          testWidgets('${pose.name} x$scale ${brightness.name}', (t) async {
            final c = await pumpPrivacy(t, pose, scale, brightness);
            final safe = pose.safe;
            final scroll = find.byKey(const Key('privacy-scroll'));
            for (var step = 0; step < 30; step++) {
              expect(t.takeException(), isNull, reason: 'step $step');
              for (final group in find.byType(SettingsGroup).evaluate()) {
                final r = t.getRect(find.byWidget(group.widget));
                expect(r.left, greaterThanOrEqualTo(safe.left - .5));
                expect(r.right, lessThanOrEqualTo(safe.right + .5));
              }
              await t.drag(scroll, Offset(0, -pose.size.height / 2));
              await t.pump(const Duration(milliseconds: 50));
            }
            c.dispose();
          });
        }
      }
    }
  });

  group('AI disclosure', () {
    Future<(JarvisController, ValueNotifier<bool?>)> open(
      WidgetTester t, {
      Pose? pose,
      DuoLayout? layout,
      double scale = 1,
      Brightness brightness = Brightness.light,
    }) async {
      final p =
          pose ??
          const Pose(
            'Pro portrait',
            Size(402, 874),
            EdgeInsets.only(top: 62, bottom: 34),
          );
      sizeWindow(t, p.size, p.insets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final answer = ValueNotifier<bool?>(null);
      await t.pumpWidget(
        withLayout(
          layout ?? layoutFor(p),
          appHost(
            Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async => answer.value =
                        await showAiDisclosure(context, controller: c),
                    child: const Text('开'),
                  ),
                ),
              ),
            ),
            scale: scale,
            brightness: brightness,
          ),
        ),
      );
      await t.tap(find.text('开'));
      await t.pumpAndSettle();
      return (c, answer);
    }

    testWidgets('同意 returns true, 暂不 returns false', (t) async {
      var (c, answer) = await open(t);
      expect(find.textContaining('人工智能'), findsOneWidget);
      expect(find.textContaining('https://jarvis.example.com'), findsOneWidget);
      await t.tap(find.text('同意'));
      await t.pumpAndSettle();
      expect(answer.value, isTrue);
      c.dispose();
      (c, answer) = await open(t);
      await t.tap(find.text('暂不'));
      await t.pumpAndSettle();
      expect(answer.value, isFalse);
      c.dispose();
    });

    testWidgets('it can open the privacy page', (t) async {
      final (c, _) = await open(t);
      await t.tap(find.byKey(const Key('disclosure-privacy')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('privacy-scroll')), findsOneWidget);
      c.dispose();
    });

    testWidgets('half-folded: inside the right pane', (t) async {
      final (c, _) = await open(
        t,
        pose: const Pose(
          'half-fold',
          Size(951, 669),
          EdgeInsets.only(right: 84, bottom: 34),
        ),
        layout: halfFolded,
      );
      final r = dialogSurface(t);
      expect(r.left, greaterThanOrEqualTo(495.5));
      expect(r.right, lessThanOrEqualTo(867));
      c.dispose();
    });

    final poses = [...straightPoses, ...foldPoses];
    for (final pose in poses) {
      for (final scale in textScales) {
        for (final brightness in Brightness.values) {
          testWidgets('${pose.name} x$scale ${brightness.name}', (t) async {
            final (c, _) = await open(
              t,
              pose: pose,
              scale: scale,
              brightness: brightness,
            );
            expect(t.takeException(), isNull);
            final safe = pose.safe;
            final surface = dialogSurface(t);
            expect(surface.left, greaterThanOrEqualTo(safe.left - .5));
            expect(surface.right, lessThanOrEqualTo(safe.right + .5));
            expect(surface.top, greaterThanOrEqualTo(safe.top - .5));
            expect(surface.bottom, lessThanOrEqualTo(safe.bottom + .5));
            for (final label in ['同意', '暂不']) {
              final button = find.ancestor(
                of: find.text(label),
                matching: find.bySubtype<ButtonStyleButton>(),
              );
              expect(
                t.getSize(button).height,
                greaterThanOrEqualTo(44 - .5),
                reason: label,
              );
            }
            c.dispose();
          });
        }
      }
    }
  });
}
