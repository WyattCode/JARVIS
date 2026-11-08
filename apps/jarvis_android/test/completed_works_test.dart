import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/completed_works.dart';

import 'support.dart';

import 'package:jarvis_android/ui/action_menu.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

void main() {
  testWidgets('Completed work waits while the conversation drawer is in use', (
    t,
  ) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    final allowed = ValueNotifier(false);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: allowed,
            builder: (_, value, _) => CompletedWorksPresenter(
              controller: c,
              allowPresentation: value,
              child: const Text('聊天'),
            ),
          ),
        ),
      ),
    );
    c.current.tasks.add(
      MediaTask(
        id: 'drawer',
        kind: 'video',
        prompt: 'ready',
        args: {},
        status: 'completed',
        urls: ['https://example.test/drawer.mp4'],
      ),
    );
    c.notifyDraftSuggestion();
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('作品'), findsNothing);
    allowed.value = true;
    await t.pump();
    await t.pump(workPresentDelay);
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('作品'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    allowed.dispose();
    c.dispose();
  });

  testWidgets('Removed completed work cannot open a stale empty sheet', (
    t,
  ) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompletedWorksPresenter(controller: c, child: const Text('聊天')),
        ),
      ),
    );
    final task = MediaTask(
      id: 'removed',
      kind: 'video',
      prompt: 'removed',
      args: {},
      status: 'completed',
      urls: ['https://example.test/removed.mp4'],
    );
    c.current.tasks.add(task);
    c.notifyDraftSuggestion();
    c.current.tasks.remove(task);
    c.notifyDraftSuggestion();
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('作品'), findsNothing);
    c.current.tasks.add(task);
    c.notifyDraftSuggestion();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('作品'), findsNothing);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Work completion does not interrupt an open action menu', (
    t,
  ) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompletedWorksPresenter(
            controller: c,
            child: JarvisActionMenu(
              tooltip: '会话操作',
              actions: const [JarvisMenuAction('rename', '重命名')],
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byTooltip('会话操作'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 120));
    expect(JarvisActionMenu.isOpen, true);
    c.current.tasks.add(
      MediaTask(
        id: 'menu',
        kind: 'video',
        prompt: 'ready',
        args: {},
        status: 'completed',
        urls: ['https://example.test/menu.mp4'],
      ),
    );
    c.notifyDraftSuggestion();
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('作品'), findsNothing);
    JarvisActionMenu.closeOpen();
    await t.pump();
    await t.pump(workPresentDelay);
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('作品'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  for (final guard in ['recording', 'another page']) {
    testWidgets('Completed works wait for $guard before opening', (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompletedWorksPresenter(
              controller: c,
              child: const Text('聊天'),
            ),
          ),
        ),
      );
      final navigator = Navigator.of(t.element(find.text('聊天')));
      if (guard == 'recording') {
        c.voice.held = true;
      } else {
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('设置')),
          ),
        );
        await t.pump();
        await t.pump(const Duration(milliseconds: 350));
      }
      c.current.tasks.add(
        MediaTask(
          id: 'waiting',
          kind: 'video',
          prompt: 'ready',
          args: {},
          status: 'completed',
          urls: ['https://example.test/ready.mp4'],
        ),
      );
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('作品'), findsNothing);
      if (guard == 'recording') {
        c.voice.held = false;
      } else {
        navigator.pop();
      }
      await t.pump(workPresentDelay);
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 350));
      expect(find.text('作品'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets(
    'Completion opens works once, preserves history and coalesces simultaneous results',
    (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final old = MediaTask(
        id: 'old',
        kind: 'video',
        prompt: 'old',
        args: {},
        status: 'completed',
        urls: ['https://example.test/old.mp4'],
      );
      c.current.tasks.add(old);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompletedWorksPresenter(
              controller: c,
              child: const Text('聊天'),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('作品'), findsNothing);
      final a = MediaTask(id: 'new', kind: 'video', prompt: 'new', args: {});
      c.current.tasks.add(a);
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('作品'), findsNothing);
      a.status = 'completed';
      a.urls = ['https://example.test/new.mp4'];
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 150));
      expect(find.text('作品'), findsNothing, reason: 'waits a second');
      await t.pump(workPresentDelay);
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('作品'), findsOneWidget);
      expect(t.widget<MediaCard>(find.byType(MediaCard).first).task.id, 'new');
      final b = MediaTask(
        id: 'new2',
        kind: 'video',
        prompt: 'new2',
        args: {},
        status: 'completed',
        urls: ['https://example.test/new2.mp4'],
      );
      c.current.tasks.add(b);
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('作品'), findsOneWidget);
      await t.pump(workPresentDelay);
      Navigator.of(t.element(find.text('作品'))).pop();
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('作品'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
