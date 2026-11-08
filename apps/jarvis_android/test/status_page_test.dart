import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/status_page.dart';

import 'support.dart';

class ScriptedStatusApi extends FakeApi {
  final replies = <Completer<Map<String, dynamic>>>[];
  int calls = 0;
  @override
  Future<Map<String, dynamic>> toolsStatus() {
    calls++;
    final c = Completer<Map<String, dynamic>>();
    replies.add(c);
    return c.future;
  }
}

Map<String, dynamic> sample() => {
  'data': [
    {'name': 'qwen3-asr', 'state': 'ready'},
    {'name': 'fish-tts', 'state': 'loading'},
    {'name': 'vision', 'state': 'failed'},
    {'name': 'video', 'state': 'unloaded'},
  ],
  'mem_available_bytes': 3221225472,
};

void main() {
  late ScriptedStatusApi api;
  late JarvisController c;

  Future<void> open(WidgetTester t, Size size) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDisplayFeatures);
    api = ScriptedStatusApi();
    c = JarvisController(api, MemoryVault());
    await c.initialize();
    await t.pumpWidget(MaterialApp(home: StatusPage(controller: c)));
    await t.pump();
  }

  Future<void> answer(WidgetTester t, Map<String, dynamic> data) async {
    api.replies.last.complete(data);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Reading shows the label; rows carry 12pt dots and 13pt labels', (
    t,
  ) async {
    await open(t, const Size(425, 800));
    expect(find.text('正在读取模型状态'), findsOneWidget);
    await answer(t, sample());
    expect(find.text('正在读取模型状态'), findsNothing);
    expect(find.byKey(const Key('status-row')), findsNWidgets(4));
    expect(
      t.getSize(find.byKey(const Key('status-dot')).first),
      const Size(12, 12),
    );
    expect(t.widget<Text>(find.text('已就绪')).style?.fontSize, 13);
    expect(find.text('可用内存 3.0 GiB'), findsOneWidget);
    // Tones: ready is the success colour, failed the error colour.
    Color dot(int i) =>
        ((t
                    .widget<Container>(
                      find.byKey(const Key('status-dot')).at(i),
                    )
                    .decoration)
                as BoxDecoration)
            .color!;
    expect(dot(0), const Color(0xff196a52));
    expect(
      dot(2),
      Theme.of(t.element(find.byType(StatusPage))).colorScheme.error,
    );
    expect(find.byKey(const Key('status-wide')), findsNothing);
  });

  testWidgets('A failed refresh keeps the last status and says so', (t) async {
    await open(t, const Size(425, 800));
    await answer(t, sample());
    expect(find.byKey(const Key('status-failed-banner')), findsNothing);
    await t.tap(find.byTooltip('刷新状态'));
    await t.pump();
    // Still the list, with a thin progress bar over it; not a spinner page.
    expect(find.byKey(const Key('status-row')), findsNWidgets(4));
    expect(find.byKey(const Key('status-progress')), findsOneWidget);
    api.replies.last.completeError(StateError('offline'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('status-row')), findsNWidgets(4));
    expect(find.text('刷新失败，显示的是上一次的状态'), findsOneWidget);
    expect(find.byKey(const Key('status-progress')), findsNothing);
    // The next good read clears the banner.
    await t.tap(find.byTooltip('刷新状态'));
    await t.pump();
    await answer(t, sample());
    expect(find.text('刷新失败，显示的是上一次的状态'), findsNothing);
  });

  testWidgets('Without data a failure offers a retry; an empty list says so', (
    t,
  ) async {
    await open(t, const Size(425, 800));
    api.replies.last.completeError(StateError('offline'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('暂时无法读取模型状态'), findsOneWidget);
    await t.tap(find.text('重试'));
    await t.pump();
    expect(api.calls, 2);
    await answer(t, {'data': []});
    expect(find.byKey(const Key('status-empty')), findsOneWidget);
    expect(find.text('服务暂未返回模型状态'), findsOneWidget);
  });

  testWidgets('Pull to refresh reads again', (t) async {
    await open(t, const Size(425, 800));
    await answer(t, sample());
    await t.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(api.calls, 2);
    api.replies.last.complete(sample());
    await t.pumpAndSettle();
  });

  testWidgets(
    'Wide: the summary column is max(280, 0.4 width) beside the list',
    (t) async {
      await open(t, const Size(860, 608));
      await answer(t, sample());
      expect(find.byKey(const Key('status-wide')), findsOneWidget);
      final summary = t.getRect(find.byKey(const Key('status-summary')));
      expect(summary.width, closeTo(860 * .4, .5));
      expect(
        t.getRect(find.byKey(const Key('status-row')).first).left,
        greaterThan(summary.right),
      );
      // Portrait and narrow windows keep the single card.
      t.view.physicalSize = const Size(608, 860);
      await t.pump();
      expect(find.byKey(const Key('status-wide')), findsNothing);
    },
  );

  testWidgets('Half-folded sideways: summary left, models right, none on the '
      'crease', (t) async {
    await open(t, const Size(860, 608));
    t.view.displayFeatures = [
      const ui.DisplayFeature(
        bounds: ui.Rect.fromLTWH(425, 0, 10, 608),
        type: ui.DisplayFeatureType.fold,
        state: ui.DisplayFeatureState.postureHalfOpened,
      ),
    ];
    await answer(t, sample());
    expect(find.byKey(const Key('status-fold-split')), findsOneWidget);
    expect(
      t.getRect(find.byKey(const Key('status-summary'))).right,
      lessThanOrEqualTo(425),
    );
    for (final r in find.byKey(const Key('status-row')).evaluate()) {
      final rect = t.getRect(find.byWidget(r.widget));
      expect(rect.left, greaterThanOrEqualTo(435));
    }
    expect(t.takeException(), isNull);
  });
}
