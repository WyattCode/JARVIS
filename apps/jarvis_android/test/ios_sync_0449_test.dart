import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/completed_works.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'support.dart';

void main() {
  testWidgets('Completion waits through typing and opens after focus leaves', (t) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    final focus = FocusNode();
    final text = TextEditingController(text: '未发送草稿');
    await t.pumpWidget(MaterialApp(home: Scaffold(body: CompletedWorksPresenter(
      controller: c, child: TextField(focusNode: focus, controller: text),
    ))));
    focus.requestFocus();
    await t.pump();
    c.current.tasks.add(MediaTask(id: 'ready', kind: 'video', prompt: '完成', args: {},
      status: 'completed', urls: ['https://example.test/video.mp4']));
    c.notifyDraftSuggestion();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('生成作品'), findsNothing);
    expect(focus.hasFocus, isTrue);
    // A second completion while still composing remains deferred too.
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('生成作品'), findsNothing);
    focus.unfocus();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('生成作品'), findsOneWidget);
    expect(text.text, '未发送草稿');
    await t.pumpWidget(const SizedBox());
    focus.dispose(); text.dispose(); c.dispose();
  });

  testWidgets('Landscape sidebar choice survives portrait and back', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1000, 700);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
    await t.pump();
    expect(find.byTooltip('收起会话'), findsOneWidget);
    await t.tap(find.byTooltip('收起会话'));
    await t.pump(const Duration(milliseconds: 250));
    t.view.physicalSize = const Size(700, 1000);
    await t.pump();
    t.view.physicalSize = const Size(1000, 700);
    await t.pump();
    await t.pump(const Duration(milliseconds: 250));
    expect(find.byTooltip('展开会话'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Slow rendering batches deltas while final answer is immediate', (t) async {
    final api = FakeApi();
    final c = JarvisController(api, MemoryVault());
    await c.initialize(); await c.login('Wyatt', 'test');
    c.setDraft('test');
    final send = c.send();
    await t.pump();
    c.reportStreamBuild(const Duration(milliseconds: 40));
    var notifications = 0;
    c.addListener(() => notifications++);
    final stream = api.streams.values.single;
    stream.add(const ChatDelta(text: '第一段'));
    await t.pump();
    expect(c.current.messages.last.text, '第一段');
    await t.pump(const Duration(milliseconds: 40));
    expect(notifications, 0);
    stream.add(const ChatDelta(text: '最后一段', done: true));
    await t.pump();
    await stream.close(); await send;
    expect(c.current.messages.last.text, '第一段最后一段');
    expect(notifications, 1);
    c.dispose();
  });
}
