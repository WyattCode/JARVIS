import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

import 'b_chat_ui_test.dart'
    show editing, halfFolded, longChat, pumpPhone, startStreaming;
import 'duo_rail_test.dart' show duoLandscape, duoOuter, pumpHome;
import 'support.dart';

void main() {
  group('composer', () {
    testWidgets('its buttons and the effort menu keep the keyboard up', (
      t,
    ) async {
      await pumpPhone(t);
      await t.tap(find.byKey(const Key('chat-input')));
      await t.pump();
      expect(editing(), isTrue);
      await t.enterText(find.byKey(const Key('chat-input')), '你好');
      await t.tap(find.byTooltip('选择思考深度'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(editing(), isTrue, reason: '打开思考深度菜单');
      await t.tap(find.text('低'));
      await t.pump(const Duration(milliseconds: 200));
      expect(editing(), isTrue, reason: '选了一项');
      await t.tap(find.byTooltip('发送'));
      await t.pump();
      expect(editing(), isTrue, reason: '点发送');
      // Anywhere else still hides it.
      await t.tap(find.text('JARVIS'));
      await t.pump();
      expect(editing(), isFalse);
      await t.pump(const Duration(seconds: 3));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('attaching fails with a plain message, not an exception dump', (
      t,
    ) async {
      await pumpPhone(t);
      // The file picker itself blows up with a raw exception.
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        (_) async => throw Exception('picker crashed'),
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          null,
        ),
      );
      await t.tap(find.byTooltip('添加附件'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('添加附件失败，请重试'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      await t.pump(const Duration(seconds: 4));
    });

    for (final foldable in [false, true]) {
      testWidgets(
        'a welcome card fills the draft and puts the caret in the input (${foldable ? 'web cards' : 'plain cards'})',
        (t) async {
          final c = foldable
              ? await pumpHome(t, duoOuter, size: const Size(466, 678))
              : await pumpPhone(t);
          await t.tap(find.byKey(const ValueKey('starter-1')));
          await t.pump();
          final prompt = c.starters[1].prompt;
          expect(c.current.draft, prompt);
          expect(editing(), isTrue);
          final field = t.widget<TextField>(
            find.byKey(const Key('chat-input')),
          );
          expect(field.controller!.text, prompt);
          expect(
            field.controller!.selection,
            TextSelection.collapsed(offset: prompt.length),
          );
          await t.pump(const Duration(seconds: 3));
        },
      );
    }
  });

  group('back to the bottom', () {
    testWidgets('appears when you scroll away from a streaming reply', (
      t,
    ) async {
      final api = FakeApi();
      final c = await pumpPhone(t, api: api, seed: longChat);
      final stream = await startStreaming(t, c, api);
      final jump = find.byKey(const Key('jump-to-latest'));
      // The button pops in and out of the tree.
      double opacity() => jump.evaluate().isEmpty ? 0 : 1;
      final position = t
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(opacity(), 0, reason: '跟随中不需要');
      await t.drag(find.byType(ListView).first, const Offset(0, 500));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(opacity(), 1);
      expect(
        t.getSize(
          find.descendant(of: jump, matching: find.byType(SizedBox)).first,
        ),
        const Size.square(44),
      );
      final away = position.extentAfter;
      expect(away, greaterThan(100));
      stream.add(ChatDelta(text: '新内容。' * 40));
      await t.pump(const Duration(milliseconds: 60));
      expect(
        position.extentAfter,
        greaterThanOrEqualTo(away),
        reason: '没有被拉回底部',
      );
      await t.tap(jump);
      await t.pump();
      // The glide takes 250 ms, then the button pops away.
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(position.extentAfter, closeTo(0, 1));
      expect(opacity(), 0);
      // Done streaming: a short way up no longer offers it...
      stream.add(const ChatDelta(done: true));
      await stream.close();
      await t.pump(const Duration(milliseconds: 300));
      await t.drag(find.byType(ListView).first, const Offset(0, 200));
      await t.pump(const Duration(milliseconds: 300));
      expect(position.extentAfter, lessThan(400));
      expect(opacity(), 0);
      // ...a long way up (more than 400 px) does, even though nothing is being written.
      await t.drag(find.byType(ListView).first, const Offset(0, 400));
      await t.pump(const Duration(milliseconds: 300));
      expect(position.extentAfter, greaterThan(400));
      expect(opacity(), 1);
      // The tap glides back (250 ms) instead of jumping, then the button is gone.
      await t.tap(jump);
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(position.extentAfter, greaterThan(1));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(position.extentAfter, closeTo(0, 1));
      expect(opacity(), 0);
      await t.pump(const Duration(seconds: 3));
    });
  });

  group('copy feedback', () {
    final copied = <String>[];
    final haptics = <Object?>[];
    setUp(() {
      copied.clear();
      haptics.clear();
    });
    void mockPlatform(WidgetTester t) {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
    }

    for (final foldable in [false, true]) {
      testWidgets(
        'copying a reply shows a check for a moment (${foldable ? 'foldable' : 'phone'})',
        (t) async {
          mockPlatform(t);
          void seed(c) => c.current.messages
            ..add(ChatMessage('user', '你好'))
            ..add(ChatMessage('assistant', '你好，我是贾维斯'));
          foldable
              ? await pumpHome(t, duoLandscape, seed: seed)
              : await pumpPhone(t, seed: seed);
          await t.tap(find.byTooltip('复制回复'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 300));
          expect(copied, ['你好，我是贾维斯']);
          expect(haptics, contains('HapticFeedbackType.selectionClick'));
          expect(find.byIcon(Icons.check_rounded), findsOneWidget);
          expect(find.byIcon(Icons.copy_outlined), findsNothing);
          expect(find.byTooltip('已复制'), findsOneWidget);
          await t.pump(const Duration(milliseconds: 1500));
          await t.pump(const Duration(milliseconds: 300));
          expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
          expect(find.byIcon(Icons.check_rounded), findsNothing);
        },
      );
    }

    testWidgets('copying a prompt from a work card confirms in place', (
      t,
    ) async {
      mockPlatform(t);
      final c = await pumpPhone(t);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaCard(
              task: MediaTask(
                id: 'm',
                kind: 'image',
                prompt: '一只猫',
                args: {},
                status: 'failed',
              ),
              controller: c,
            ),
          ),
        ),
      );
      await t.tap(find.text('复制提示词'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(copied, ['一只猫']);
      expect(find.text('已复制'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.text('复制提示词'), findsOneWidget);
    });
  });

  group('errors', () {
    testWidgets(
      'an interrupted reply says so in the error colour and can be retried',
      (t) async {
        final c = await pumpPhone(
          t,
          seed: (c) {
            c
              ..authenticated = true
              ..model = 'test-model';
            c.current.messages
              ..add(ChatMessage('user', '你好'))
              ..add(
                ChatMessage(
                  'assistant',
                  '说到一半',
                  status: 'interrupted',
                  error: '网络中断',
                ),
              );
          },
        );
        final colors = Theme.of(t.element(find.text('网络中断'))).colorScheme;
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
        expect(t.widget<Text>(find.text('网络中断')).style!.color, colors.error);
        await t.tap(find.text('重试'));
        await t.pump();
        final messages = c.current.messages;
        expect(messages.where((m) => m.hidden).map((m) => m.role), [
          'user',
          'assistant',
        ], reason: '重试 = 重新生成这条回复：旧的一轮被收起');
        expect(messages.where((m) => !m.hidden).first.text, '你好');
        await t.pump(const Duration(seconds: 3));
      },
    );

    testWidgets('the error line opens its full text and can be dismissed', (
      t,
    ) async {
      final c = await pumpPhone(t);
      const long = '连接失败：服务器返回了很长的一段说明，超过三行也要能看全。\n第二行\n第三行\n第四行';
      c.error = long;
      c.notifyDraftSuggestion();
      await t.pump();
      // The line grows in; wait for it to settle before pressing it.
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byKey(const Key('error-line')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(
        find.byWidgetPredicate((w) => w is SelectableText && w.data == long),
        findsOneWidget,
      );
      await t.tap(find.text('关闭'));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byKey(const Key('error-dismiss')));
      await t.pump();
      expect(find.byKey(const Key('error-line')), findsNothing);
      c.error = '另一个错误';
      c.notifyDraftSuggestion();
      await t.pump();
      expect(find.byKey(const Key('error-line')), findsOneWidget);
      await t.pump(const Duration(seconds: 3));
    });
  });

  group('links', () {
    final calls = <MethodCall>[];
    void mockLauncher(WidgetTester t, Future<Object?> Function(MethodCall) on) {
      calls.clear();
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) {
          calls.add(call);
          return on(call);
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        ),
      );
    }

    Future<void> pumpLinks(WidgetTester t) => pumpPhone(
      t,
      seed: (c) => c.current.messages
        ..add(ChatMessage('user', '链接'))
        ..add(ChatMessage('assistant', '[a](https://example.com)')),
    );
    Future<void> tapLink(WidgetTester t, String href) async {
      t.widget<MarkdownBody>(find.byType(MarkdownBody)).onTapLink!(
        'x',
        href,
        '',
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
    }

    testWidgets('mail and phone links open, scripts do not', (t) async {
      mockLauncher(t, (_) async => true);
      await pumpLinks(t);
      await tapLink(t, 'mailto:user@example.com');
      await tapLink(t, 'tel:+8613800000000');
      await tapLink(t, 'https://example.com/a');
      await tapLink(t, 'javascript:alert(1)');
      final urls = [for (final c in calls) (c.arguments as Map)['url']];
      expect(urls, [
        'mailto:user@example.com',
        'tel:+8613800000000',
        'https://example.com/a',
      ]);
      expect(find.text('无法打开链接'), findsNothing);
      await t.pump(const Duration(seconds: 4));
    });

    for (final failure in ['refuses', 'throws']) {
      testWidgets('a link the system $failure says so', (t) async {
        mockLauncher(t, (_) async {
          if (failure == 'throws') {
            throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
          }
          return false;
        });
        await pumpLinks(t);
        await tapLink(t, 'mailto:user@example.com');
        expect(find.text('无法打开链接'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pump(const Duration(seconds: 4));
      });
    }
  });

  group('half-folded', () {
    bool crossesFold(Rect rect) => rect.right > 455.5 && rect.left < 495.5;

    testWidgets(
      'the messages, the composer and its buttons stay off the fold',
      (t) async {
        void seed(c) => c.current.messages
          ..add(ChatMessage('user', '你好，请写一段很长的话。' * 6))
          ..add(ChatMessage('assistant', '这是一段会换很多行的回复。' * 40));
        // Flat: the composer does lie across the fold's band.
        await pumpHome(t, duoLandscape, seed: seed);
        final flat = t.getRect(find.byKey(const Key('composer-frame')));
        expect(crossesFold(flat), isTrue);

        await pumpHome(t, halfFolded, seed: seed);
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        final composer = t.getRect(find.byKey(const Key('composer-frame')));
        expect(crossesFold(composer), isFalse);
        for (final control in [
          find.byTooltip('添加附件'),
          find.byTooltip('选择思考深度'),
          find.byIcon(Icons.mic_none_rounded).last,
        ]) {
          expect(crossesFold(t.getRect(control)), isFalse);
          expect(composer.contains(t.getRect(control).center), isTrue);
        }
        for (final text
            in find
                .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(RichText),
                )
                .evaluate()) {
          final rect = t.getRect(find.byWidget(text.widget));
          expect(crossesFold(rect), isFalse, reason: '$rect');
        }
        expect(t.takeException(), isNull);
      },
    );

    testWidgets('the column is 20% wider than the usual 85% of its side', (
      t,
    ) async {
      await pumpHome(t, halfFolded);
      final composer = t.getRect(find.byKey(const Key('composer-frame')));
      // The side right of the fold is 371.5 wide: the frame fills it down to an 8 pt gap at the crease and 16 pt at the
      // strip (it was ~272).
      expect(composer.width, closeTo(371.5 - 24, 1));
      expect(composer.left, closeTo(495.5 + 8, .5));
      expect(composer.right, closeTo(951 - 84 - 16, .5));
    });

    testWidgets('folding and unfolding fades the column through the switch', (
      t,
    ) async {
      final layout = ValueNotifier(duoLandscape);
      await pumpHome(t, duoLandscape, notifier: layout);
      double fade() =>
          t.widget<Opacity>(find.byKey(const Key('fold-fade'))).opacity;
      final flat = t.getRect(find.byKey(const Key('composer-frame')));
      expect(fade(), 1);

      Future<void> run(DuoLayout to) async {
        layout.value = to;
        await t.pump();
        await t.pump(const Duration(milliseconds: 16));
        await t.pump(const Duration(milliseconds: 150));
        expect(fade(), lessThan(.3), reason: 'dips while the layout switches');
        await t.pump(const Duration(milliseconds: 400));
        expect(fade(), 1);
      }

      await run(halfFolded);
      expect(
        t.getRect(find.byKey(const Key('composer-frame'))).left,
        greaterThanOrEqualTo(495.5),
      );
      await run(duoLandscape);
      expect(t.getRect(find.byKey(const Key('composer-frame'))), flat);
    });

    testWidgets('the composer keeps its unfolded height and bottom gap', (
      t,
    ) async {
      await pumpHome(t, duoLandscape);
      final flat = t.getRect(find.byKey(const Key('composer-frame')));
      await pumpHome(t, halfFolded);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final folded = t.getRect(find.byKey(const Key('composer-frame')));
      expect(folded.height, flat.height);
      expect(folded.bottom, flat.bottom);
    });

    testWidgets('the welcome cards keep off it too', (t) async {
      await pumpHome(t, halfFolded);
      for (var i = 0; i < 4; i++) {
        expect(
          crossesFold(t.getRect(find.byKey(ValueKey('starter-$i')))),
          isFalse,
        );
      }
    });
  });
}
