import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/action_menu.dart';
import 'package:jarvis_android/ui/completed_works.dart';
import 'package:jarvis_android/ui/media_widgets.dart';
import 'package:jarvis_android/ui/video_source.dart';

import 'support.dart';

class CountingApi extends FakeApi {
  final started = <String>[];
  int running = 0, peak = 0;
  @override
  Future<Uint8List> download(String path) async {
    started.add(path);
    peak = running = running + 1 > peak ? running + 1 : peak;
    final now = running;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    running = now - 1;
    return Uint8List.fromList([1, 2, 3]);
  }
}

MediaTask done(String id, {String kind = 'video'}) => MediaTask(
  id: id,
  kind: kind,
  prompt: id,
  args: {},
  status: 'completed',
  urls: ['https://example.test/$id.mp4'],
);

void main() {
  group('generated works', () {
    testWidgets('the panel lists the newest work first', (t) async {
      t.view.physicalSize = const Size(800, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      // Conversations are kept newest first; each one appends its tasks.
      c.conversations
        ..clear()
        ..addAll([
          Conversation('new', tasks: [done('n1'), done('n2')]),
          Conversation('old', tasks: [done('o1'), done('o2')]),
        ]);
      c.selectedId = 'new';
      late BuildContext context;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      unawaited(showGeneratedWorks(context, c));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final ids = [
        for (final card in t.widgetList<MediaCard>(find.byType(MediaCard)))
          card.task.id,
      ];
      expect(ids, ['n2', 'n1', 'o2', 'o1']);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('it waits while a text field has the focus, then opens', (
      t,
    ) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompletedWorksPresenter(
              controller: c,
              child: const TextField(autofocus: true),
            ),
          ),
        ),
      );
      await t.pump();
      expect(FocusManager.instance.primaryFocus?.hasPrimaryFocus, isTrue);
      final typing = done('typing');
      final urls = typing.urls;
      typing
        ..status = 'in_progress'
        ..urls = const [];
      c.current.tasks.add(typing);
      c.notifyDraftSuggestion();
      typing
        ..status = 'completed'
        ..urls = urls;
      c.notifyDraftSuggestion();
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 400));
      }
      expect(find.text('生成作品'), findsNothing, reason: '打字时不弹出');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('生成作品'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('video cards', () {
    testWidgets('a card follows its video when the url changes', (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      final task = done('v');
      Future<void> pump() => t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaCard(task: task, controller: c),
          ),
        ),
      );
      await pump();
      expect(
        find.byKey(const ValueKey('cover-https://example.test/v.mp4')),
        findsOneWidget,
      );
      task.urls = ['https://example.test/other.mp4'];
      await pump();
      expect(
        find.byKey(const ValueKey('cover-https://example.test/v.mp4')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('cover-https://example.test/other.mp4')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('open-https://example.test/other.mp4')),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
    });

    testWidgets(
      'iOS: a video is fetched once when opened, and only the two newest stay on disk',
      (t) async {
        final api = CountingApi();
        final c = JarvisController(api, MemoryVault());
        await c.initialize();
        addTearDown(c.dispose);
        addTearDown(clearVideoCache);
        await t.runAsync(() async {
          Future<File> open(String id) async => File(
            Uri.parse((await openVideo(c, '/v1/videos/$id/content')).dataSource)
                .toFilePath(),
          );
          final a = await open('a');
          final again = await open('a');
          expect(again.path, a.path, reason: '同一个视频只下载一次');
          expect(api.started, hasLength(1));
          final b = await open('b');
          expect(a.existsSync() && b.existsSync(), isTrue);
          final cFile = await open('c');
          expect(a.existsSync(), isFalse, reason: '最旧的文件被删除，tmp 不会无限增长');
          expect(b.existsSync() && cFile.existsSync(), isTrue);
          await clearVideoCache();
          expect(b.existsSync() || cFile.existsSync(), isFalse);
        });
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('action menu', () {
    testWidgets('unmounting a page with an open menu does not throw', (
      t,
    ) async {
      final visible = ValueNotifier(true);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, show, _) => show
                  ? JarvisActionMenu(
                      tooltip: '会话操作',
                      actions: const [JarvisMenuAction('rename', '重命名')],
                      onSelected: (_) {},
                    )
                  : const SizedBox(),
            ),
          ),
        ),
      );
      await t.tap(find.byTooltip('会话操作'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(JarvisActionMenu.isOpen, isTrue);
      visible.value = false;
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(t.takeException(), isNull);
      expect(JarvisActionMenu.isOpen, isFalse);
      // Back now goes to the page, not to a menu that is gone.
      final navigator = Navigator.of(t.element(find.byType(Scaffold)));
      expect(navigator.canPop(), isFalse);
      await t.pumpWidget(const SizedBox());
      visible.dispose();
    });
  });
}
