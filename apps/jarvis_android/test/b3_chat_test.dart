import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/markdown_style.dart';

import 'b2_support.dart';
import 'b3_support.dart';
import 'support.dart';

const _phone = Device(
  'phone',
  Size(400, 800),
  safe: EdgeInsets.only(top: 40, bottom: 34),
);

Finder reply(String text) => find.textContaining(text, findRichText: true);

void main() {
  group('the welcome page on straight iPhones', () {
    for (final device in straightPhones) {
      for (final scale in [1.0, 2.4]) {
        testWidgets('${device.name} x$scale: cards are whole and tappable', (
          t,
        ) async {
          final c = await pumpWired(t, device, scale: scale);
          expect(t.takeException(), isNull);
          var shown = 0;
          for (var i = 0; i < c.starters.length; i++) {
            final card = find.byKey(ValueKey('starter-$i'));
            if (card.evaluate().isEmpty) continue;
            // No room at all (a short window at a large text size): the whole row is hidden, never cropped.
            final folded = t
                .widgetList<Align>(
                  find.ancestor(of: card, matching: find.byType(Align)),
                )
                .any((a) => a.heightFactor == 0);
            if (folded) continue;
            shown++;
            // Never half-revealed: every fade / clip / pointer guard above a card is either fully on or off.
            for (final o in t.widgetList<Opacity>(
              find.ancestor(of: card, matching: find.byType(Opacity)),
            )) {
              expect(o.opacity, anyOf(0, 1), reason: 'starter-$i');
            }
            for (final g in t.widgetList<IgnorePointer>(
              find.ancestor(of: card, matching: find.byType(IgnorePointer)),
            )) {
              expect(g.ignoring, isFalse, reason: 'starter-$i');
            }
            c.current.draft = '';
            await t.ensureVisible(card);
            await t.pump();
            await t.tap(card, warnIfMissed: false);
            await t.pump();
            expect(c.current.draft, c.starters[i].prompt, reason: 'starter-$i');
          }
          // The reported bug: the 17 Pro Max in landscape left its cards cropped at a fraction of their height.
          if (device.name == '17 Pro Max landscape' && scale == 1) {
            expect(shown, c.starters.length);
          }
          await t.pump(const Duration(seconds: 2));
        });
      }
    }

    testWidgets('a card adds to a draft the user already wrote', (t) async {
      final c = await pumpWired(
        t,
        _phone,
        seed: (c) => c.current.draft = '先看看这个',
      );
      await t.tap(find.byKey(const ValueKey('starter-1')));
      await t.pump();
      expect(c.current.draft, '先看看这个\n${c.starters[1].prompt}');
      final field = t.widget<TextField>(find.byKey(const Key('chat-input')));
      expect(
        field.controller!.selection,
        TextSelection.collapsed(offset: c.current.draft.length),
        reason: '光标在末尾',
      );
      await t.pump(const Duration(seconds: 2));
    });
  });

  group('reading width', () {
    for (final device in straightPhones) {
      final landscape = device.size.width > device.size.height;
      testWidgets('${device.name}: messages and composer share one column', (
        t,
      ) async {
        await pumpWired(t, device, seed: someMessages);
        final frame = t.getRect(find.byKey(const Key('composer-frame')));
        final bubbles = rectsOf(
          t,
          find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey &&
                '${(w.key as ValueKey).value}'.startsWith('bubble-'),
          ),
        );
        final usable = device.size.width - device.safe.left - device.safe.right;
        if (landscape && usable > 720) {
          expect(frame.width, lessThanOrEqualTo(720));
          expect(frame.center.dx, closeTo(device.size.width / 2, 1));
        } else {
          // Portrait and short landscapes are untouched: the composer keeps the whole width less its 10 pt gaps.
          expect(frame.width, closeTo(usable - 20, 1));
        }
        for (final r in bubbles) {
          expect(r.width, lessThanOrEqualTo(landscape ? 720 : usable));
        }
        await t.pump(const Duration(seconds: 2));
      });
    }
  });

  group('messages', () {
    testWidgets('a reply the user stopped is a grey note, not an error', (
      t,
    ) async {
      await pumpWired(
        t,
        _phone,
        seed: (c) {
          connected(c);
          c.current.messages
            ..add(ChatMessage('user', '你好'))
            ..add(ChatMessage('assistant', '说到一半', status: 'interrupted'));
        },
      );
      final colors = Theme.of(t.element(find.text('已停止'))).colorScheme;
      expect(find.text('回复已中断'), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(
        t.widget<Text>(find.text('已停止')).style!.color,
        colors.onSurfaceVariant,
      );
      expect(find.text('重试'), findsOneWidget, reason: '仍可重试');
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('the tool-call line is small, grey and level with the reply', (
      t,
    ) async {
      final api = FakeApi();
      final c = await pumpWired(t, _phone, api: api, seed: connected);
      c.setDraft('hi');
      unawaited(c.send());
      await t.pump();
      // The model has asked for a tool and the reply has no text yet.
      c.current.messages.last.calls.add(ToolCall());
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 100));
      final line = find.text('正在调用工具…');
      expect(line, findsOneWidget);
      final style = t.widget<Text>(line).style!;
      expect(style.fontSize, lessThan(14));
      expect(
        find.descendant(
          of: find.ancestor(of: line, matching: find.byType(Row)).first,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      // Same left edge as a reply bubble's content (18 pt page margin, no extra indent).
      expect(t.getTopLeft(find.byType(CircularProgressIndicator).last).dx, 18);
      await api.streams.values.single.close();
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('a reply is one selection area, not a field per paragraph', (
      t,
    ) async {
      await pumpWired(
        t,
        _phone,
        seed: (c) => c.current.messages
          ..add(ChatMessage('user', '你好'))
          ..add(
            ChatMessage(
              'assistant',
              '第一段\n\n第二段\n\n- 列表一\n- 列表二\n\n```dart\nprint(1);\n```',
            ),
          ),
      );
      expect(find.byType(SelectionArea), findsOneWidget);
      final inReply = find.descendant(
        of: find.byType(SelectionArea),
        matching: find.byType(SelectableText),
      );
      expect(inReply, findsNothing);
      expect(find.byTooltip('复制回复'), findsOneWidget, reason: '复制键仍在');
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets(
      'Arabic and Hebrew replies run right to left, Chinese does not',
      (t) async {
        await pumpWired(
          t,
          _phone,
          seed: (c) => c.current.messages
            ..add(ChatMessage('user', 'مرحبا كيف حالك'))
            ..add(ChatMessage('assistant', 'שלום, מה שלומך?'))
            ..add(ChatMessage('user', '你好 مرحبا'))
            ..add(ChatMessage('assistant', '你好，有什么可以帮你？')),
        );
        TextDirection of(Finder f) =>
            t.widget<SelectableText>(f).textDirection ?? TextDirection.ltr;
        final user = find.byType(SelectableText);
        expect(of(user.at(0)), TextDirection.rtl);
        expect(of(user.at(1)), TextDirection.ltr, reason: '中文开头仍是从左到右');
        final rtlReply = find.ancestor(
          of: reply('שלום'),
          matching: find.byWidgetPredicate(
            (w) => w is Directionality && w.textDirection == TextDirection.rtl,
          ),
        );
        expect(rtlReply, findsWidgets);
        final ltrReply = find.ancestor(
          of: reply('有什么可以帮你'),
          matching: find.byWidgetPredicate(
            (w) => w is Directionality && w.textDirection == TextDirection.rtl,
          ),
        );
        expect(ltrReply, findsNothing);
        await t.pump(const Duration(seconds: 2));
      },
    );

    test('the first strong letter decides the direction', () {
      expect(textDirectionOf('hello'), TextDirection.ltr);
      expect(textDirectionOf('你好'), TextDirection.ltr);
      expect(textDirectionOf('123 ... مرحبا'), TextDirection.rtl);
      expect(textDirectionOf('שלום'), TextDirection.rtl);
      expect(textDirectionOf('😀 123'), isNull);
      expect(textDirectionOf(''), isNull);
    });

    testWidgets('a reply that hit the length limit offers to go on', (t) async {
      var continued = 0;
      await pumpWired(
        t,
        _phone,
        onContinue: () => continued++,
        seed: (c) {
          connected(c);
          c.current.messages
            ..add(ChatMessage('user', '写一篇长文'))
            ..add(ChatMessage('assistant', '很长很长……', status: 'length'));
        },
      );
      expect(find.text('已达到输出长度上限'), findsOneWidget);
      final button = find.byKey(const Key('continue-reply'));
      expect(t.getSize(button).height, greaterThanOrEqualTo(44));
      await t.tap(button);
      expect(continued, 1);
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('without a continue hook the limit note stays as it was', (
      t,
    ) async {
      await pumpWired(
        t,
        _phone,
        seed: (c) => c.current.messages
          ..add(ChatMessage('user', '写一篇长文'))
          ..add(ChatMessage('assistant', '很长很长……', status: 'length')),
      );
      expect(find.text('已达到输出长度上限'), findsOneWidget);
      expect(find.byKey(const Key('continue-reply')), findsNothing);
      await t.pump(const Duration(seconds: 2));
    });
  });

  group('streaming', () {
    test('long replies are laid out less often', () {
      expect(streamingInterval(100), Duration.zero);
      expect(streamingInterval(4000), Duration.zero);
      expect(streamingInterval(4001), const Duration(milliseconds: 100));
      expect(streamingInterval(20000), const Duration(milliseconds: 200));
    });

    testWidgets(
      'a long streaming reply lags by one interval, a short one does not',
      (t) async {
        final api = FakeApi();
        final c = await pumpWired(t, _phone, api: api, seed: connected);
        c.setDraft('hi');
        unawaited(c.send());
        await t.pump();
        final stream = api.streams.values.single;
        int shown() => t
            .widgetList<Text>(find.byType(Text, skipOffstage: false))
            .where(
              (w) =>
                  (w.textSpan?.toPlainText() ?? w.data ?? '').startsWith('字'),
            )
            .map((w) => (w.textSpan?.toPlainText() ?? w.data!).length)
            .fold(0, (a, b) => a > b ? a : b);
        stream.add(ChatDelta(text: '字' * 100));
        await t.pump(const Duration(milliseconds: 40));
        stream.add(ChatDelta(text: '字' * 10));
        await t.pump(const Duration(milliseconds: 40));
        expect(shown(), 110, reason: '短回复逐段跟随');
        stream.add(ChatDelta(text: '字' * 5000));
        await t.pump(const Duration(milliseconds: 40));
        final first = shown();
        expect(first, 5110, reason: '越过阈值的第一次立即显示');
        stream.add(ChatDelta(text: '字' * 10));
        await t.pump(const Duration(milliseconds: 40));
        expect(shown(), first, reason: '冷却时间内保持上一版');
        await t.pump(const Duration(milliseconds: 100));
        expect(shown(), first + 10, reason: '冷却结束后显示最新');
        stream.add(const ChatDelta(done: true));
        await stream.close();
        await t.pump(const Duration(seconds: 2));
      },
    );
  });

  group('composer', () {
    testWidgets(
      'a draft that cannot be sent says why, once connected it does not',
      (t) async {
        final c = await pumpWired(t, _phone);
        expect(find.byKey(const Key('send-blocked')), findsNothing);
        await t.enterText(find.byKey(const Key('chat-input')), '你好');
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('模型未连接，暂时无法发送'), findsOneWidget);
        final handle = t.ensureSemantics();
        final send = t.getSemantics(find.byTooltip('发送')).getSemanticsData();
        expect(send.hint, '模型未连接，暂时无法发送');
        expect(send.flagsCollection.isButton, isTrue);
        handle.dispose();
        connected(c);
        c.notifyDraftSuggestion();
        await t.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('send-blocked')), findsNothing);
        await t.pump(const Duration(seconds: 2));
      },
    );

    testWidgets('the thinking-depth trigger is a labelled button', (t) async {
      final handle = t.ensureSemantics();
      await pumpWired(t, _phone);
      final node = t.getSemantics(find.byTooltip('选择思考深度'));
      expect(node.label, contains('思考深度，当前'));
      expect(node.flagsCollection.isButton, isTrue);
      handle.dispose();
      await t.pump(const Duration(seconds: 2));
    });

    for (final (message, expected) in [
      (PlatformException(code: 'image_invalid', message: '图片尺寸过大'), '图片尺寸过大'),
      (
        PlatformException(code: 'image_invalid', message: '压缩后超过3MB'),
        '压缩后超过3MB',
      ),
      (PlatformException(code: 'image_too_large'), '图片尺寸过大，请换一张较小的图片'),
      (
        PlatformException(code: 'compress_failed', message: 'x'),
        '图片压缩后仍超过 3MB，请换一张较小的图片',
      ),
      (const JarvisException('每条消息最多4个附件'), '每条消息最多4个附件'),
      (Exception('boom'), '添加附件失败，请重试'),
    ]) {
      test('attachment error ${message.runtimeType}: $expected', () {
        expect(attachmentErrorText(message), expected);
      });
    }

    testWidgets(
      'increase contrast: composer, cards and user bubble use the full outline',
      (t) async {
        await pumpWired(
          t,
          _phone,
          highContrast: true,
          seed: (c) => c.current.messages.add(ChatMessage('user', '你好')),
        );
        final scheme = Theme.of(
          t.element(find.byKey(const Key('composer-frame'))),
        ).colorScheme;
        Border? borderOf(Finder f) =>
            (t.widget<Container>(f).decoration as BoxDecoration).border
                as Border?;
        expect(
          borderOf(find.byKey(const Key('composer-frame')))!.top.color,
          scheme.outline,
        );
        final bubble = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey &&
              '${(w.key as ValueKey).value}'.startsWith('bubble-'),
        );
        expect(borderOf(bubble)!.top.color, scheme.outline);
        await t.pump(const Duration(seconds: 2));
      },
    );
  });

  group('the page', () {
    testWidgets(
      'an error line grows in, closes with 关闭, and the offline bar offers a retry',
      (t) async {
        var retried = 0;
        var offline = true;
        final c = await pumpWired(
          t,
          _phone,
          offline: () => offline,
          onRetry: () => retried++,
        );
        expect(find.text('网络不可用，历史记录为本机副本'), findsOneWidget);
        await t.tap(find.byKey(const Key('offline-retry')));
        expect(retried, 1);
        expect(
          t.getSize(find.byKey(const Key('offline-retry'))).height,
          greaterThanOrEqualTo(44),
        );
        c.error = '出错了';
        c.notifyDraftSuggestion();
        await t.pump();
        await t.pump(const Duration(milliseconds: 100));
        final partway = t.getSize(find.byKey(const Key('error-line'))).height;
        await t.pump(const Duration(milliseconds: 300));
        expect(find.byTooltip('关闭'), findsOneWidget);
        expect(find.byTooltip('忽略'), findsNothing);
        expect(find.byType(AnimatedSize), findsWidgets);
        expect(partway, greaterThan(0));
        await t.tap(find.byKey(const Key('error-dismiss')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('error-line')), findsNothing);
        offline = false;
        c.notifyDraftSuggestion();
        await t.pump();
        expect(find.byKey(const Key('offline-bar')), findsNothing);
        await t.pump(const Duration(seconds: 2));
      },
    );

    testWidgets('the offline bar does not exist unless asked for', (t) async {
      await pumpWired(t, _phone);
      expect(find.byKey(const Key('offline-bar')), findsNothing);
      await t.pump(const Duration(seconds: 2));
    });
  });

  group('conversation list', () {
    Conversation made(
      String id,
      String title, {
      List<String> said = const [],
    }) => Conversation(
      id,
      title: title,
      // A message's id carries its time, like the ones the app makes.
      messages: [for (final s in said) ChatMessage('user', s, id: id)],
    );

    test(
      'rows are grouped by the day of the last message and filtered by search',
      () {
        final now = DateTime(2026, 10, 29, 15);
        String stamp(DateTime d) => '${d.microsecondsSinceEpoch}-0';
        final a = made(stamp(now), '今天的');
        final b = made(stamp(now.subtract(const Duration(days: 1))), '昨天的');
        final c = made(
          stamp(now.subtract(const Duration(days: 5))),
          '很早的',
          said: ['苹果'],
        );
        final d = made('legacy-id', '没有时间的');
        expect(conversationRows([a, b, c, d], '', now), [
          '今天',
          a,
          '昨天',
          b,
          '更早',
          c,
          d,
        ]);
        expect(conversationRows([a, b], '', now), ['今天', a, '昨天', b]);
        expect(conversationRows([a, d], '', now), ['今天', a, '更早', d]);
        expect(conversationRows([c, d], '', now), [c, d], reason: '只有一组时不加标题');
        expect(conversationRows([a, b, c, d], '苹果', now), [c]);
        expect(conversationRows([a, b, c, d], '没有', now), [d]);
        expect(conversationRows([a, b, c, d], '不存在', now), isEmpty);
      },
    );

    testWidgets('a long list gets a search field that filters it', (t) async {
      final c = await pumpWired(
        t,
        _phone,
        seed: (c) {
          for (var i = 0; i < 7; i++) {
            c.conversations.add(Conversation('x$i', title: '主题 $i'));
          }
        },
      );
      await t.tap(find.byTooltip('展开会话'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('conversation-search')), findsOneWidget);
      await t.enterText(find.byKey(const Key('conversation-search')), '主题 3');
      await t.pump();
      final list = find.byKey(const Key('conversation-list'));
      expect(
        find.descendant(of: list, matching: find.text('主题 3')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: list, matching: find.text('主题 4')),
        findsNothing,
      );
      await t.enterText(find.byKey(const Key('conversation-search')), '没有这个');
      await t.pump();
      expect(find.text('没有匹配的会话'), findsOneWidget);
      expect(c.conversations.length, greaterThan(7));
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('a short list has no search field', (t) async {
      await pumpWired(t, _phone);
      await t.tap(find.byTooltip('展开会话'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('conversation-search')), findsNothing);
      await t.pump(const Duration(seconds: 2));
    });
  });

  group('deleting a conversation', () {
    Future<JarvisController> setup(
      WidgetTester t, {
      bool accessible = false,
      void Function(MediaTask)? onCancel,
      bool pending = false,
    }) async {
      final c = await pumpWired(
        t,
        _phone,
        accessibleNavigation: accessible,
        onCancelTask: onCancel,
        seed: (c) {
          c.conversations.add(Conversation('other', title: '另一个'));
          if (pending) {
            c.current.tasks.add(
              MediaTask(id: 'job', kind: 'video', prompt: 'x', args: {}),
            );
          }
        },
      );
      await t.tap(find.byTooltip('展开会话'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      return c;
    }

    Future<void> deleteFirst(WidgetTester t) async {
      await t.tap(find.byTooltip('会话操作').first);
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.text('删除').last);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
    }

    for (final accessible in [false, true]) {
      testWidgets(
        'the undo notice outlasts the swipe: ${accessible ? '8' : '5'} s',
        (t) async {
          await setup(t, accessible: accessible);
          await deleteFirst(t);
          expect(find.byKey(const Key('sidebar-notice')), findsOneWidget);
          await t.pump(Duration(seconds: accessible ? 7 : 4));
          expect(find.byKey(const Key('sidebar-notice')), findsOneWidget);
          await t.pump(const Duration(seconds: 2));
          await t.pump(const Duration(milliseconds: 400));
          expect(find.byKey(const Key('sidebar-notice')), findsNothing);
          await t.pump(const Duration(seconds: 2));
        },
      );
    }

    testWidgets('a conversation with a pending task offers to cancel it', (
      t,
    ) async {
      final cancelled = <String>[];
      final c = await setup(
        t,
        pending: true,
        onCancel: (task) => cancelled.add(task.id),
      );
      expect(c.canDeleteConversation(c.current.id), isFalse);
      // The pending one is the current (first listed after 新建? use the menu of whichever row holds the task).
      final rows = find.byTooltip('会话操作');
      for (var i = 0; i < rows.evaluate().length; i++) {
        await t.tap(rows.at(i));
        await t.pump();
        await t.pump(const Duration(milliseconds: 200));
        await t.tap(find.text('删除').last);
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        if (find.text('取消任务').evaluate().isNotEmpty) break;
      }
      expect(find.textContaining('个生成任务在运行'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.text('取消任务'));
      await t.pump();
      expect(cancelled, ['job']);
      await t.pump(const Duration(seconds: 7));
    });

    testWidgets('without a cancel hook the refusal keeps its old words', (
      t,
    ) async {
      final c = await setup(t, pending: true);
      expect(c.canDeleteConversation(c.current.id), isFalse);
      final rows = find.byTooltip('会话操作');
      for (var i = 0; i < rows.evaluate().length; i++) {
        await t.tap(rows.at(i));
        await t.pump();
        await t.pump(const Duration(milliseconds: 200));
        await t.tap(find.text('删除').last);
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        if (find.textContaining('请先结束此会话').evaluate().isNotEmpty) break;
      }
      expect(find.textContaining('请先结束此会话的任务或通话'), findsOneWidget);
      expect(find.text('取消任务'), findsNothing);
      await t.pump(const Duration(seconds: 7));
    });
  });

  group('haptics', () {
    testWidgets('send, stop and new conversation tick', (t) async {
      final ticks = <Object?>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            ticks.add(call.arguments);
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
      final api = FakeApi();
      await pumpWired(
        t,
        _phone,
        api: api,
        seed: (c) {
          connected(c);
          c.settings.aiNoticeAccepted = true;
        },
      );
      await t.enterText(find.byKey(const Key('chat-input')), '你好');
      await t.pump();
      await t.tap(find.byTooltip('发送'));
      await t.pump();
      expect(ticks, ['HapticFeedbackType.selectionClick']);
      await t.tap(find.byTooltip('停止当前回复'));
      await t.pump();
      expect(ticks.last, 'HapticFeedbackType.lightImpact');
      ticks.clear();
      await t.tap(find.byKey(const Key('start-new-chat')));
      await t.pump();
      expect(ticks, ['HapticFeedbackType.selectionClick']);
      await t.pump(const Duration(seconds: 2));
    });
  });
}
