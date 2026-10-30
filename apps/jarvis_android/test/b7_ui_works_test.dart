import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/completed_works.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

import 'b_chat_ui_test.dart' show halfFolded;
import 'c2_voice_test.dart' show pumpVoice;
import 'duo_rail_test.dart' show duoLandscape;
import 'support.dart';

MediaTask finished(String id) => MediaTask(
  id: id,
  kind: 'video',
  prompt: id,
  args: {},
  status: 'completed',
  urls: ['https://example.test/$id.mp4'],
);

/// Half-folded in portrait: the fold is an active horizontal band at y 455.5..495.5.
final portraitFold = DuoLayout.fromMap({
  'edge': 'none',
  'width': 669.0,
  'height': 951.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 0.0, 'bottom': 34.0},
  'regions': [
    {
      'kind': 'division',
      'active': true,
      'x': 0.0,
      'y': 455.5,
      'w': 669.0,
      'h': 40.0,
    },
  ],
});

void main() {
  Future<JarvisController> pumpPresenter(WidgetTester t) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompletedWorksPresenter(controller: c, child: const Text('聊天')),
        ),
      ),
    );
    return c;
  }

  testWidgets('a backup import does not present its finished works', (t) async {
    final c = await pumpPresenter(t);
    c.installImported([
      Conversation('imported', title: '导入')
        ..tasks.addAll([finished('h1'), finished('h2')]),
    ]);
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('生成作品'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(MediaCard), findsNothing);
    // A job that runs now and finishes is still news, shown first.
    final job = MediaTask(id: 'job', kind: 'video', prompt: 'job', args: {});
    c.current.tasks.add(job);
    c.notifyDraftSuggestion();
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('生成作品'), findsNothing);
    job
      ..status = 'completed'
      ..urls = ['https://example.test/job.mp4'];
    c.notifyDraftSuggestion();
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('生成作品'), findsOneWidget);
    expect(t.widget<MediaCard>(find.byType(MediaCard).first).task.id, 'job');
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a job restored as running and finished later is presented', (
    t,
  ) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    final job = MediaTask(
      id: 'resumed',
      kind: 'video',
      prompt: 'resumed',
      args: {},
      status: 'in_progress',
    );
    c.current.tasks.add(job);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompletedWorksPresenter(controller: c, child: const Text('聊天')),
        ),
      ),
    );
    job
      ..status = 'completed'
      ..urls = ['https://example.test/resumed.mp4'];
    c.notifyDraftSuggestion();
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('生成作品'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('the notice action does nothing once the page is gone', (
    t,
  ) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    final shown = ValueNotifier(true);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (_, on, _) => on
                ? CompletedWorksPresenter(
                    controller: c,
                    child: const Text('聊天'),
                  )
                : const Text('别的页面'),
          ),
        ),
      ),
    );
    // A finger on the screen: the work is announced by a notice instead of a sheet.
    await t.tap(find.text('聊天'));
    final job = MediaTask(id: 'job', kind: 'video', prompt: 'job', args: {});
    c.current.tasks.add(job);
    c.notifyDraftSuggestion();
    job
      ..status = 'completed'
      ..urls = ['https://example.test/job.mp4'];
    c.notifyDraftSuggestion();
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('作品已生成'), findsOneWidget);
    shown.value = false;
    await t.pump();
    await t.tap(find.text('查看'));
    await t.pump(const Duration(milliseconds: 500));
    expect(t.takeException(), isNull);
    expect(find.text('生成作品'), findsNothing);
    await t.pump(const Duration(seconds: 5));
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  group('the sheet on the folded iPhone Duo', () {
    Future<Rect> openSheet(
      WidgetTester t,
      DuoLayout layout,
      Size size,
      EdgeInsets padding,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      t.view.padding = FakeViewPadding(
        right: padding.right,
        bottom: padding.bottom,
      );
      t.view.viewPadding = t.view.padding;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewPadding);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      c.current.tasks.add(finished('a'));
      await t.pumpWidget(
        DuoLayoutScope(
          layout: ValueNotifier(layout),
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showGeneratedWorks(context, c),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('生成作品'), findsOneWidget);
      return t.getRect(
        find
            .ancestor(of: find.text('生成作品'), matching: find.byType(Material))
            .first,
      );
    }

    testWidgets('flat landscape: centred, at most 640 wide, 80% high', (
      t,
    ) async {
      final r = await openSheet(
        t,
        duoLandscape,
        const Size(951, 669),
        duoLandscape.safe,
      );
      expect(r.width, 640);
      expect(r.center.dx, closeTo((0 + 867) / 2, 1));
      expect(r.height, closeTo(669 * .8, 1));
      expect(r.bottom, 669);
    });

    testWidgets('half-folded in landscape: right of the crease only', (
      t,
    ) async {
      final r = await openSheet(
        t,
        halfFolded,
        const Size(951, 669),
        halfFolded.safe,
      );
      expect(r.left, greaterThanOrEqualTo(495.5));
      expect(r.right, lessThanOrEqualTo(867));
      expect(r.center.dx, closeTo((495.5 + 867) / 2, 1));
    });

    testWidgets('half-folded in portrait: stays below the crease', (t) async {
      final r = await openSheet(
        t,
        portraitFold,
        const Size(669, 951),
        portraitFold.safe,
      );
      expect(r.top, greaterThanOrEqualTo(495.5));
      expect(r.bottom, 951);
    });
  });

  testWidgets('a running work can be cancelled from the call page', (t) async {
    final c = await pumpVoice(t, size: const Size(402, 874), works: true);
    final task = c.current.tasks.single;
    expect(task.pending, true);
    await t.tap(find.textContaining('生成作品 ·'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.text('取消'));
    await t.pump();
    expect(task.status, 'interrupted');
    expect(t.takeException(), isNull);
    await t.pump(const Duration(seconds: 1));
    await t.pumpWidget(const SizedBox());
  });
}
