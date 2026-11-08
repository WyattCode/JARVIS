import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/completed_works.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

import 'support.dart';

MediaTask ready(String id) => MediaTask(
  id: id,
  kind: 'video',
  prompt: id,
  args: {},
  status: 'completed',
  urls: ['https://example.test/$id.mp4'],
);

void main() {
  testWidgets(
    'Retained focus gets actionable completion without losing draft',
    (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final focus = FocusNode();
      final text = TextEditingController(text: '未发送草稿');
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompletedWorksPresenter(
              controller: c,
              child: TextField(focusNode: focus, controller: text),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await t.pump();
      c.current.tasks.add(ready('one'));
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 200));
      await t.pump();
      expect(find.text('作品'), findsNothing);
      expect(find.byKey(const Key('completed-work-notice')), findsOneWidget);
      expect(focus.hasFocus, true);
      await t.tap(find.byKey(const Key('completed-work-notice')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('作品'), findsOneWidget);
      expect(text.text, '未发送草稿');
      await t.pumpWidget(const SizedBox());
      focus.dispose();
      text.dispose();
      c.dispose();
    },
  );

  testWidgets(
    'Background completion opens only its owner gallery when explicitly selected',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(600, 2400);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.current.tasks.add(ready('current'));
      final other = Conversation('other', title: '另一个会话');
      c.conversations.add(other);
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
      other.tasks.add(ready('background'));
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 200));
      await t.pump();
      expect(find.text('作品'), findsNothing);
      expect(find.textContaining('另一个会话'), findsOneWidget);
      final selected = c.selectedId;
      await t.tap(find.byKey(const Key('completed-work-notice')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      // The sheet lists the works of every conversation; the one that has
      // just finished stands first.
      expect(find.byType(MediaCard), findsNWidgets(2));
      expect(
        t.widget<MediaCard>(find.byType(MediaCard).first).task.id,
        'background',
      );
      expect(c.selectedId, selected);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'Reading protection and return to latest integrate with completed works',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(608, 860);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      for (var i = 0; i < 30; i++) {
        c.current.messages.add(ChatMessage('assistant', '历史内容 $i\n' * 6));
      }
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final list = find.byType(ListView).last;
      await t.drag(list, const Offset(0, 400));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(c.readingHistoryId, c.current.id);
      expect(find.byKey(const Key('return-to-latest')), findsOneWidget);
      c.current.messages.last.text += '新回复';
      c.notifyDraftSuggestion();
      await t.pump();
      // The button says there is a new reply (to a reader of the screen).
      expect(
        t
            .widget<Semantics>(
              find
                  .descendant(
                    of: find.byKey(const Key('return-to-latest')),
                    matching: find.byType(Semantics),
                  )
                  .first,
            )
            .properties
            .label,
        '有新回复，回到底部',
      );
      c.current.tasks.add(ready('read'));
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 200));
      await t.pump();
      expect(find.text('作品'), findsNothing);
      expect(find.byKey(const Key('completed-work-notice')), findsOneWidget);
      expect(
        t.getRect(find.byKey(const Key('completed-work-notice'))).bottom,
        lessThan(t.getRect(find.byKey(const Key('return-to-latest'))).top),
      );
      await t.tap(find.byKey(const Key('return-to-latest')));
      await t.pump();
      await t.pump();
      expect(c.readingHistoryId, isNull);
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('作品'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'Dismissing a background reminder acknowledges it without opening a modal',
    (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final other = Conversation('other');
      c.conversations.add(other);
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
      other.tasks.add(ready('background'));
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 200));
      await t.pump();
      await t.tap(find.byTooltip('忽略此次完成提醒'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('completed-work-notice')), findsNothing);
      expect(find.text('作品'), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Another conversation result is retained while a gallery is open',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(600, 2400);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final other = Conversation('other', title: '后台会话');
      c.conversations.add(other);
      c.current.tasks.add(ready('old'));
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
      showGeneratedWorks(t.element(find.text('聊天')), c);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      other.tasks.add(ready('new-other'));
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 200));
      // The sheet lists every conversation's works, the new one first; the
      // reminder for it is still kept for after the sheet closes.
      expect(find.byType(MediaCard), findsNWidgets(2));
      expect(
        t.widget<MediaCard>(find.byType(MediaCard).first).task.id,
        'new-other',
      );
      Navigator.of(t.element(find.text('作品'))).pop();
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('completed-work-notice')), findsOneWidget);
      expect(find.textContaining('后台会话'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
