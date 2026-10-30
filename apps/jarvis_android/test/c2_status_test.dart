import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';
import 'package:jarvis_android/ui/status_page.dart';

import 'c2_support.dart';
import 'support.dart';

/// A status endpoint whose answers the test hands out one at a time.
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

Future<(JarvisController, QueueStatusApi)> pumpStatus(
  WidgetTester t, {
  Size size = const Size(402, 874),
  EdgeInsets insets = const EdgeInsets.only(top: 62, bottom: 34),
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  sizeWindow(t, size, insets);
  final api = QueueStatusApi();
  final c = JarvisController(api, MemoryVault());
  await c.initialize();
  addTearDown(c.dispose);
  await t.pumpWidget(
    appHost(
      StatusPage(controller: c),
      scale: scale,
      brightness: brightness,
    ),
  );
  await t.pump();
  return (c, api);
}

void main() {
  testWidgets('the first load shows a spinner, then the grouped rows', (
    t,
  ) async {
    final (_, api) = await pumpStatus(t);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    api.pending.single.complete(
      status([('语音模型', 'ready'), ('图片模型', 'loading')]),
    );
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('已就绪'), findsOneWidget);
    // The rows sit in one settings card, with the dot close to the name.
    expect(find.byType(SettingsGroup), findsOneWidget);
    final tile = t.widget<ListTile>(find.byType(ListTile).first);
    expect(tile.minLeadingWidth, lessThan(40));
    expect(t.takeException(), isNull);
  });

  testWidgets('refresh keeps the list and shows a thin bar; no assertion', (
    t,
  ) async {
    final (_, api) = await pumpStatus(t);
    api.pending.single.complete(status([('语音模型', 'ready')]));
    await t.pump();
    await t.tap(find.byTooltip('刷新状态'));
    await t.pump();
    // The old data stays; only a thin bar says a refresh is running.
    expect(find.text('已就绪'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      t.getSize(find.byType(LinearProgressIndicator)).height,
      lessThanOrEqualTo(2),
    );
    expect(api.pending, hasLength(2));
    api.pending.last.complete(status([('语音模型', 'busy')]));
    await t.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('正在处理'), findsOneWidget);
    expect(find.text('已就绪'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('a failed refresh keeps the old rows and says so', (t) async {
    final (_, api) = await pumpStatus(t);
    api.pending.single.complete(status([('语音模型', 'ready')]));
    await t.pump();
    await t.tap(find.byTooltip('刷新状态'));
    await t.pump();
    api.pending.last.completeError(JarvisException('offline'));
    await t.pump();
    expect(find.text('已就绪'), findsOneWidget);
    expect(find.text('刷新失败，显示的是上一次的状态'), findsOneWidget);
    // Trying again clears the message.
    await t.tap(find.byTooltip('刷新状态'));
    await t.pump();
    expect(find.text('刷新失败，显示的是上一次的状态'), findsNothing);
    api.pending.last.complete(status([('语音模型', 'idle')]));
    await t.pump();
    expect(find.text('空闲'), findsOneWidget);
  });

  testWidgets('a first load that fails offers a retry, the retry works', (
    t,
  ) async {
    final (_, api) = await pumpStatus(t);
    api.pending.single.completeError(JarvisException('offline'));
    await t.pump();
    expect(find.text('暂时无法读取模型状态'), findsOneWidget);
    await t.tap(find.text('重试'));
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    api.pending.last.complete(status([('语音模型', 'ready')]));
    await t.pump();
    expect(find.text('已就绪'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('a slow earlier answer does not overwrite a newer one', (
    t,
  ) async {
    final (_, api) = await pumpStatus(t);
    api.pending.single.complete(status([('语音模型', 'ready')]));
    await t.pump();
    await t.tap(find.byTooltip('刷新状态'));
    await t.pump();
    await t.tap(find.byTooltip('刷新状态'));
    await t.pump();
    api.pending[2].complete(status([('语音模型', 'idle')]));
    await t.pump();
    api.pending[1].complete(status([('语音模型', 'error')]));
    await t.pump();
    expect(find.text('空闲'), findsOneWidget);
    expect(find.text('需要检查'), findsNothing);
  });

  group('every device', () {
    for (final pose in [...straightPoses, ...foldPoses]) {
      for (final scale in textScales) {
        testWidgets('status ${pose.name} x$scale', (t) async {
          final (_, api) = await pumpStatus(
            t,
            size: pose.size,
            insets: pose.insets,
            scale: scale,
            brightness: scale == 1.5 ? Brightness.dark : Brightness.light,
          );
          api.pending.single.complete(
            status([
              for (var i = 0; i < 12; i++) ('模型 $i · 长名称不会侵入系统安全区的显示', 'ready'),
            ]),
          );
          await t.pump();
          expect(t.takeException(), isNull);
          final safe = pose.safe;
          final scroll = find.byType(Scrollable).first;
          for (var step = 0; step < 6; step++) {
            for (final e in find.byType(ListTile).evaluate()) {
              final r = t.getRect(find.byWidget(e.widget));
              expect(r.left, greaterThanOrEqualTo(safe.left - .5));
              expect(r.right, lessThanOrEqualTo(safe.right + .5));
            }
            await t.drag(scroll, Offset(0, -pose.size.height / 2));
            await t.pump();
            expect(t.takeException(), isNull);
          }
        });
      }
    }
  });
}
