import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/markdown_style.dart';
import 'package:jarvis_android/ui/settings_page.dart';

import 'duo_rail_test.dart' show duoLandscape, duoOuter, pumpHome;
import 'support.dart';

/// The inner display, half-folded in landscape: the fold is an active vertical band at x 455.5..495.5.
final halfFolded = DuoLayout.fromMap({
  'edge': 'right',
  'width': 951.0,
  'height': 669.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
  'regions': [
    {
      'kind': 'division',
      'active': true,
      'x': 455.5,
      'y': 0.0,
      'w': 40.0,
      'h': 669.0,
    },
    {
      'kind': 'occlusion',
      'active': true,
      'x': 867.0,
      'y': 0.0,
      'w': 84.0,
      'h': 124.0,
    },
  ],
});

bool editing() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>() !=
    null;

Future<JarvisController> pumpPhone(
  WidgetTester t, {
  TargetPlatform? platform,
  Size size = const Size(400, 800),
  void Function(JarvisController)? seed,
  FakeApi? api,
}) => pumpHome(
  t,
  DuoLayout.none,
  size: size,
  insets: EdgeInsets.zero,
  platform: platform,
  seed: seed,
  api: api,
);

Future<void> openDrawer(WidgetTester t) async {
  await t.tap(find.byTooltip('展开会话'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

/// Enough history to scroll, ending with a reply that carries a long reasoning section.
void longChat(JarvisController c, {String? reasoning}) {
  for (var i = 0; i < 12; i++) {
    c.current.messages
      ..add(ChatMessage('user', '问题 $i'))
      ..add(
        ChatMessage(
          'assistant',
          '这是第 $i 个回答。' * 12,
          reasoning: i == 11 ? reasoning ?? '' : '',
        ),
      );
  }
}

/// A logged-in controller whose reply is streaming; the returned sink feeds it.
Future<StreamController<ChatDelta>> startStreaming(
  WidgetTester t,
  JarvisController c,
  FakeApi api,
) async {
  await c.login('w', 't');
  c.setDraft('继续');
  unawaited(c.send());
  await t.pump();
  return api.streams.values.last;
}

void main() {
  group('drawer', () {
    for (final target in ['new-conversation', 'row']) {
      testWidgets(
        'a quick double tap on $target acts once and the drawer stays shut',
        (t) async {
          final c = await pumpPhone(
            t,
            seed: (c) => c.current.messages.add(ChatMessage('user', '你好')),
          );
          final before = c.conversations.length;
          await openDrawer(t);
          final button = target == 'row'
              ? find.byType(ListTile).first
              : find.byKey(const Key('new-conversation'));
          await t.tap(button);
          await t.pump(const Duration(milliseconds: 50));
          // The drawer is sliding shut: it must not catch this touch.
          await t.tap(button, warnIfMissed: false);
          await t.pump();
          await t.pump(const Duration(milliseconds: 500));
          expect(find.byType(JarvisHome), findsOneWidget);
          expect(t.takeException(), isNull);
          expect(
            t.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
            isFalse,
          );
          expect(find.byType(Drawer, skipOffstage: false), findsNothing);
          if (target == 'new-conversation') {
            expect(c.conversations.length, before + 1);
          }
        },
      );
    }

    testWidgets('settings opens once on a double tap', (t) async {
      await pumpPhone(t);
      await openDrawer(t);
      final settings = find.widgetWithText(ListTile, '设置');
      await t.tap(settings);
      await t.pump(const Duration(milliseconds: 50));
      await t.tap(settings, warnIfMissed: false);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(SettingsPage, skipOffstage: false), findsOneWidget);
      expect(find.byType(JarvisHome, skipOffstage: false), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('rows are not swipe-to-delete inside the drawer, only docked', (
      t,
    ) async {
      await pumpPhone(t, platform: TargetPlatform.iOS);
      await openDrawer(t);
      expect(find.byType(Dismissible), findsNothing);
      expect(find.byTooltip('会话操作'), findsOneWidget, reason: '菜单里仍可删除');
      await pumpHome(
        t,
        DuoLayout.none,
        size: const Size(951, 669),
        insets: EdgeInsets.zero,
        platform: TargetPlatform.iOS,
      );
      expect(find.byType(Dismissible), findsWidgets);
    });

    testWidgets('the swipe background says what it does', (t) async {
      late JarvisController c;
      await pumpHome(
        t,
        DuoLayout.none,
        size: const Size(951, 669),
        insets: EdgeInsets.zero,
        platform: TargetPlatform.iOS,
        seed: (x) {
          c = x;
          x.current.messages.add(ChatMessage('user', '你好'));
        },
      );
      final row = find.byKey(ValueKey('conversation-surface-${c.current.id}'));
      final drag = await t.startGesture(t.getCenter(row));
      await drag.moveBy(const Offset(-40, 0));
      await drag.moveBy(const Offset(-40, 0));
      await t.pump();
      expect(find.text('删除'), findsOneWidget);
      await drag.up();
      await t.pumpAndSettle();
    });

    testWidgets('the strip is not taken off the drawer content twice', (
      t,
    ) async {
      await pumpHome(t, duoOuter, size: const Size(466, 678));
      await t.tap(find.byKey(const Key('duo-rail-sidebar')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      final drawer = t.getRect(find.byType(Drawer));
      final button = t.getRect(find.byKey(const Key('new-conversation')));
      // 12pt of padding either side. (The Scaffold already strips that side from its drawer; this guards it.)
      expect(drawer.right - button.right, closeTo(12, 1));
      expect(button.left - drawer.left, closeTo(12, 1));
    });

    testWidgets('a conversation that is generating announces it', (t) async {
      final api = FakeApi();
      final handle = t.ensureSemantics();
      final c = await pumpHome(
        t,
        DuoLayout.none,
        size: const Size(951, 669),
        insets: EdgeInsets.zero,
        api: api,
      );
      final stream = await startStreaming(t, c, api);
      await t.pump(const Duration(milliseconds: 100));
      expect(find.bySemanticsLabel(RegExp('生成中')), findsOneWidget);
      stream.add(const ChatDelta(done: true));
      await stream.close();
      await t.pump(const Duration(seconds: 3));
      handle.dispose();
    });
  });

  group('messages', () {
    testWidgets('opening the reasoning at the tail keeps its start in view', (
      t,
    ) async {
      final c = await pumpPhone(
        t,
        seed: (c) => longChat(c, reasoning: '推理一步。' * 400),
      );
      final tail = t
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(tail.extentAfter, closeTo(0, 1));
      await t.tap(find.text('思考过程'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final title = t.getRect(find.text('思考过程'));
      expect(title.top, greaterThan(0));
      expect(title.bottom, lessThan(800));
      expect(tail.extentAfter, greaterThan(100));
      expect(c.current.messages, isNotEmpty);
    });

    testWidgets('reasoning is set apart from the answer', (t) async {
      final c = await pumpPhone(
        t,
        seed: (c) => longChat(c, reasoning: '推理一步。'),
      );
      await t.tap(find.text('思考过程'));
      await t.pump(const Duration(milliseconds: 400));
      final colors = Theme.of(t.element(find.text('思考过程'))).colorScheme;
      final text = t.widget<SelectableText>(
        find.byWidgetPredicate((w) => w is SelectableText && w.data == '推理一步。'),
      );
      expect(
        text.style!.fontSize,
        c.settings.messageFontSize - 1.5,
        reason: '比正文小',
      );
      expect(text.style!.color, colors.onSurfaceVariant);
      final rule = t
          .widgetList<Container>(find.byType(Container))
          .where(
            (box) =>
                box.decoration is BoxDecoration &&
                (box.decoration! as BoxDecoration).border is Border &&
                ((box.decoration! as BoxDecoration).border! as Border)
                        .left
                        .width ==
                    2,
          );
      expect(rule, hasLength(1));
      expect(
        t.getRect(find.text('推理一步。')).left - t.getRect(find.text('思考过程')).left,
        closeTo(14, 4),
        reason: '2pt 竖线加 12pt 缩进',
      );
    });

    testWidgets('the chat list has no full-height shader mask', (t) async {
      await pumpPhone(t, seed: longChat);
      expect(
        find.descendant(
          of: find.byType(ChatPanel),
          matching: find.byType(ShaderMask),
        ),
        findsNothing,
      );
      // The soft edges are two small gradient strips that let taps through.
      final strips = find
          .descendant(
            of: find.byType(ChatPanel),
            matching: find.byType(IgnorePointer),
          )
          .evaluate()
          .where((e) {
            final box = (e as SingleChildRenderObjectElement).renderObject;
            return box is RenderBox && box.size.height == 18;
          });
      expect(strips, hasLength(2));
    });

    testWidgets('the style sheet is built once per theme and size', (t) async {
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
      final a = chatMarkdownStyle(context, 16);
      expect(identical(a, chatMarkdownStyle(context, 16)), isTrue);
      expect(identical(a, chatMarkdownStyle(context, 18)), isFalse);
      expect(
        identical(chatMarkdownBuilders(16), chatMarkdownBuilders(16)),
        isTrue,
      );
    });

    testWidgets('finished replies are left alone while another one streams', (
      t,
    ) async {
      final api = FakeApi();
      final c = await pumpPhone(
        t,
        api: api,
        seed: (c) => c.current.messages
          ..add(ChatMessage('user', '你好'))
          ..add(ChatMessage('assistant', '第一条回复')),
      );
      final stream = await startStreaming(t, c, api);
      await t.pump();
      final before = t.widget<MarkdownBody>(find.byType(MarkdownBody).first);
      for (var i = 0; i < 3; i++) {
        stream.add(ChatDelta(text: '第 $i 段'));
        await t.pump(const Duration(milliseconds: 60));
      }
      expect(find.textContaining('第 2 段'), findsOneWidget);
      expect(
        identical(
          before,
          t.widget<MarkdownBody>(find.byType(MarkdownBody).first),
        ),
        isTrue,
      );
      stream.add(const ChatDelta(done: true));
      await stream.close();
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('your bubble takes 88% of the real message column', (t) async {
      await pumpHome(
        t,
        duoOuter,
        size: const Size(466, 678),
        seed: (c) => c.current.messages.add(ChatMessage('user', '很长的消息。' * 80)),
      );
      final list = t.getRect(find.byType(ListView).first);
      final inset =
          DuoLayout.edgeGap +
          (list.width - 2 * DuoLayout.edgeGap) *
              (1 - DuoLayout.replyWidthFactor) /
              2;
      final column = list.width - 2 * inset;
      final bubble = t.getRect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey &&
              '${(w.key! as ValueKey).value}'.startsWith('bubble-'),
        ),
      );
      expect(bubble.width, closeTo(column * .88, 1));
    });

    testWidgets('semantics: bubbles say who speaks', (t) async {
      final handle = t.ensureSemantics();
      final c = await pumpPhone(
        t,
        seed: (c) => c.current.messages
          ..add(ChatMessage('user', '你好'))
          ..add(ChatMessage('assistant', '你好，我是贾维斯')),
      );
      final user = find.byKey(
        ValueKey('bubble-${c.current.id}-${c.current.messages.first.id}'),
      );
      final reply = find.byKey(
        ValueKey('bubble-${c.current.id}-${c.current.messages.last.id}'),
      );
      expect(t.getSemantics(user).label, contains('你'));
      expect(t.getSemantics(reply).label, contains('JARVIS'));
      handle.dispose();
    });

    testWidgets('a hugging icon button is activated by the screen reader', (
      t,
    ) async {
      final handle = t.ensureSemantics();
      await pumpHome(
        t,
        duoLandscape,
        seed: (c) => c.current.messages
          ..add(ChatMessage('user', '你好'))
          ..add(ChatMessage('assistant', '你好，我是贾维斯')),
      );
      final node = t.getSemantics(find.bySemanticsLabel('复制回复'));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });
  });
}
