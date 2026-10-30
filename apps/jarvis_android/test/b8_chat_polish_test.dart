import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'b_chat_ui_test.dart' show editing, pumpPhone, startStreaming;
import 'support.dart';

/// How see-through [target] is: the product of every opacity layer above it.
double faded(WidgetTester t, Finder target) {
  var value = 1.0;
  for (final element
      in find.ancestor(of: target, matching: find.byType(Opacity)).evaluate()) {
    value *= (element.widget as Opacity).opacity;
  }
  for (final element
      in find
          .ancestor(of: target, matching: find.byType(FadeTransition))
          .evaluate()) {
    value *= (element.widget as FadeTransition).opacity.value;
  }
  return value;
}

/// Frames worth [ms] milliseconds in total (an animation only moves on frames, one big pump is one frame).
Future<void> frames(WidgetTester t, int ms) async {
  for (var spent = 0; spent < ms; spent += 20) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<JarvisController> pumpLogin(
  WidgetTester t, {
  TargetPlatform platform = TargetPlatform.android,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(436, 948);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetViewInsets);
  final c = JarvisController(FakeApi(), MemoryVault());
  addTearDown(c.dispose);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      // As in main.dart, the page is rebuilt whenever the controller changes.
      home: ListenableBuilder(
        listenable: c,
        builder: (_, _) => LoginPage(controller: c),
      ),
    ),
  );
  return c;
}

void main() {
  group('login', () {
    testWidgets('on iOS the form follows the keyboard inset frame by frame', (
      t,
    ) async {
      await pumpLogin(t, platform: TargetPlatform.iOS);
      final button = find.widgetWithText(FilledButton, '登录');
      final hero = find.byKey(const ValueKey('login-reactor-size'));
      final closedHero = t.getSize(hero).height;
      for (final inset in [100.0, 250.0, 400.0]) {
        t.view.viewInsets = FakeViewPadding(bottom: inset);
        await t.pump();
        // The button clears the keyboard on the very frame the inset changes: no glide of its own to wait for.
        final gap = 948 - inset - t.getBottomRight(button).dy;
        expect(gap, greaterThanOrEqualTo(8), reason: 'inset $inset');
        if (inset == 400) expect(gap, lessThanOrEqualTo(20));
      }
      expect(t.getSize(hero).height, lessThan(closedHero));
      expect(t.takeException(), isNull);
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('elsewhere the stepped inset is eased', (t) async {
      await pumpLogin(t);
      final button = find.widgetWithText(FilledButton, '登录');
      final closed = t.getBottomRight(button).dy;
      t.view.viewInsets = const FakeViewPadding(bottom: 400);
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      final gap = 948 - 400 - t.getBottomRight(button).dy;
      expect(gap, lessThan(0), reason: 'still on its way up');
      expect(t.getBottomRight(button).dy, lessThan(closed));
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('submitting drops the keyboard; connecting keeps the fields '
        'read-only, not disabled', (t) async {
      final c = await pumpLogin(t, platform: TargetPlatform.iOS);
      final fields = find.byType(TextField);
      await t.tap(fields.first);
      await t.pump();
      await t.enterText(fields.first, 'user');
      await t.enterText(fields.last, 'secret');
      await t.pump();
      expect(editing(), isTrue);
      await t.tap(find.widgetWithText(FilledButton, '登录'));
      await t.pump();
      expect(editing(), isFalse, reason: 'the keyboard falls on submit');
      // While it connects the fields are read-only, not disabled (which would grey them and drop the focus).
      c.connecting = true;
      c.notifyDraftSuggestion();
      await frames(t, 300);
      for (final element in fields.evaluate()) {
        final field = element.widget as TextField;
        expect(field.readOnly, isTrue);
        expect(field.enabled, isNot(false));
      }
      expect(find.text('正在登录…'), findsOneWidget);
      c.connecting = false;
      c.notifyDraftSuggestion();
      await frames(t, 400);
      expect(find.text('正在登录…'), findsNothing);
      expect(find.text('登录'), findsWidgets);
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('an error fades in and eases the form down instead of '
        'jumping it', (t) async {
      final c = await pumpLogin(t);
      final button = find.widgetWithText(FilledButton, '登录');
      final before = t.getTopLeft(button).dy;
      c.error = '登录失败，账户或密码不正确。请检查后再试一次，或者联系管理员重置你的密码，谢谢。' * 2;
      c.notifyDraftSuggestion();
      await t.pump();
      expect(t.getTopLeft(button).dy, closeTo(before, .5));
      await frames(t, 60);
      final partway = t.getTopLeft(button).dy;
      await frames(t, 400);
      final after = t.getTopLeft(button).dy;
      expect(after, greaterThan(before));
      expect(partway, inExclusiveRange(before, after));
      await t.pump(const Duration(seconds: 3));
    });
  });

  group('welcome page and list', () {
    testWidgets('the first message fades the welcome out while it comes in', (
      t,
    ) async {
      final api = FakeApi();
      final c = await pumpPhone(t, api: api);
      expect(find.text('想聊点什么？'), findsOneWidget);
      await startStreaming(t, c, api);
      final sent = find.descendant(
        of: find.byType(ListView),
        matching: find.text('继续'),
      );
      // Frame 0 of the first message: nothing has vanished yet.
      expect(find.text('想聊点什么？'), findsOneWidget);
      expect(sent, findsOneWidget);
      await frames(t, 60);
      expect(find.text('想聊点什么？'), findsOneWidget);
      expect(faded(t, find.text('想聊点什么？')), lessThan(1));
      // The message does not wait for the welcome to go: no blank page between the two.
      expect(faded(t, sent), greaterThan(0));
      await frames(t, 400);
      expect(find.text('想聊点什么？'), findsNothing);
      expect(sent, findsOneWidget);
      expect(faded(t, sent), 1);
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('a page built afterwards fades in; the first one does not', (
      t,
    ) async {
      final c = await pumpPhone(
        t,
        seed: (c) => c.current.messages.add(ChatMessage('user', '你好')),
      );
      // The page that was there at the start was simply there.
      expect(faded(t, find.text('你好')), 1);
      c.newConversation();
      await t.pump();
      await frames(t, 40);
      expect(faded(t, find.text('想聊点什么？')), lessThan(1), reason: '新会话的欢迎页淡入');
      await frames(t, 400);
      expect(faded(t, find.text('想聊点什么？')), 1);
      await t.pump(const Duration(seconds: 3));
    });
  });

  group('replies', () {
    testWidgets('waiting shows a spinner and the thinking header; the action '
        'row eases in once the reply is written', (t) async {
      final api = FakeApi();
      final c = await pumpPhone(t, api: api);
      final stream = await startStreaming(t, c, api);
      await frames(t, 400);
      expect(find.text('正在思考…'), findsOneWidget);
      stream.add(const ChatDelta(reasoning: '先想一想。'));
      await frames(t, 100);
      expect(find.text('思考中…'), findsOneWidget);
      expect(find.text('思考过程'), findsNothing);
      stream.add(const ChatDelta(text: '好的，这是答案。'));
      await frames(t, 100);
      expect(find.text('正在思考…'), findsNothing);
      expect(find.text('思考中…'), findsNothing);
      expect(find.text('思考过程'), findsOneWidget);
      expect(find.byTooltip('复制回复'), findsNothing, reason: '写完才出现');
      stream.add(const ChatDelta(done: true));
      await stream.close();
      await t.pump();
      await frames(t, 80);
      expect(find.byTooltip('复制回复'), findsOneWidget);
      final partway = faded(t, find.byTooltip('复制回复'));
      await frames(t, 400);
      expect(partway, lessThan(1));
      expect(find.byTooltip('重新生成'), findsOneWidget);
      // 44 pt targets on a plain phone as well.
      for (final tip in ['复制回复', '重新生成']) {
        expect(t.getSize(find.byTooltip(tip)).height, greaterThanOrEqualTo(44));
        expect(t.getSize(find.byTooltip(tip)).width, greaterThanOrEqualTo(44));
      }
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets("a code block's header is not part of a selection", (t) async {
      await pumpPhone(
        t,
        seed: (c) => c.current.messages
          ..add(ChatMessage('user', '写代码'))
          ..add(ChatMessage('assistant', '```dart\nvoid main() {}\n```')),
      );
      expect(find.byType(MarkdownBody), findsOneWidget);
      for (final header in ['复制', 'dart']) {
        final container = t.widget<SelectionContainer>(
          find
              .ancestor(
                of: find.text(header),
                matching: find.byType(SelectionContainer),
              )
              .first,
        );
        expect(container.registrar, isNull, reason: '$header 不可选');
      }
    });
  });

  group('header', () {
    testWidgets('folds away with the keyboard over 180 ms and comes back', (
      t,
    ) async {
      await pumpPhone(t);
      double pageTop() => t.getTopLeft(find.byType(ChatPanel)).dy;
      final open = pageTop();
      expect(find.byTooltip('展开会话'), findsOneWidget);
      t.view.viewInsets = const FakeViewPadding(bottom: 500);
      addTearDown(t.view.resetViewInsets);
      await t.pump();
      // Still there on the first frame, then shrinking: the page does not jump up by the header's height.
      expect(find.byTooltip('展开会话'), findsOneWidget);
      expect(pageTop(), closeTo(open, .5));
      await frames(t, 80);
      final partway = pageTop();
      expect(partway, lessThan(open));
      await frames(t, 400);
      expect(find.byTooltip('展开会话'), findsNothing);
      final closed = pageTop();
      expect(partway, greaterThan(closed));
      t.view.viewInsets = FakeViewPadding.zero;
      await t.pump();
      await frames(t, 80);
      expect(find.byTooltip('展开会话'), findsOneWidget);
      expect(pageTop(), inExclusiveRange(closed, open));
      await frames(t, 400);
      expect(pageTop(), closeTo(open, .5));
    });
  });

  group('menu', () {
    testWidgets('the panel fades and grows as one piece', (t) async {
      await pumpPhone(t);
      await t.tap(find.byTooltip('选择思考深度'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 30));
      final panel = find
          .ancestor(of: find.text('低'), matching: find.byType(Opacity))
          .first;
      expect(t.widget<Opacity>(panel).opacity, inExclusiveRange(0, 1));
      // The surface and the rows share that one opacity: no solid card with rows fading inside it.
      expect(
        find.descendant(of: panel, matching: find.byType(Opacity)),
        findsNothing,
      );
      expect(
        find.descendant(of: panel, matching: find.byType(Material)),
        findsWidgets,
      );
      await frames(t, 300);
      expect(t.widget<Opacity>(panel).opacity, 1);
    });
  });
}
