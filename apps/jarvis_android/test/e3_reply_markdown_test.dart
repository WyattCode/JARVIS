import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/markdown_style.dart';
import 'package:jarvis_android/ui/reply_markdown.dart';

import 'duo_rail_test.dart' show pumpHome;

String pad(String s) => s + ' 补充内容' * 40;

final samples = <String, String>{
  'paragraphs': List.generate(6, (i) => pad('第$i段，有**加粗**和`代码`。')).join('\n\n'),
  'headings and lists': [
    pad('## 小标题'),
    pad('介绍文字'),
    '- 第一项\n- 第二项\n- 第三项\n\n${pad('列表之后的段落')}',
    '1. 一\n2. 二\n\n3. 三（松散列表）',
    pad('### 另一个标题\n正文'),
  ].join('\n\n'),
  'fenced code with blank lines': [
    pad('先说明'),
    '```dart\nvoid main() {\n\n  print(1);\n\n}\n```',
    pad('代码之后'),
    '~~~\n\n\nsecond fence\n\n~~~',
    pad('结尾'),
  ].join('\n\n'),
  'quote and table': [
    pad('引言'),
    '> 引用第一行\n>\n> 引用第二段',
    pad('表格前'),
    '| a | b |\n|---|---|\n| 1 | 2 |',
    pad('表格后'),
  ].join('\n\n'),
  'list item with a second paragraph': [
    pad('前言'),
    '- 项目一\n\n  项目一的第二段\n\n- 项目二',
    pad('结尾'),
  ].join('\n\n'),
  'link reference': [
    pad('看[这里][a]。'),
    pad('另一段'),
    '[a]: https://example.com',
  ].join('\n\n'),
  'rtl-free numbers': List.generate(
    5,
    (i) => pad('$i. 一段以数字开头的文字'),
  ).join('\n\n'),
};

Widget host(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 360, child: child),
      ),
    ),
  ),
);

void main() {
  group('splitReply', () {
    test('short text and link references stay whole', () {
      expect(splitReply('一段\n\n另一段'), hasLength(1));
      expect(splitReply(samples['link reference']!), hasLength(1));
    });

    test('never cuts inside a fence, a list, a quote or a table', () {
      for (final e in samples.entries) {
        final blocks = splitReply(e.value);
        // Joining the blocks again gives the same text (modulo the blank lines between them).
        expect(
          blocks.join('\n\n').replaceAll(RegExp(r'\n{2,}'), '\n\n'),
          e.value.replaceAll(RegExp(r'\n{2,}'), '\n\n').trimRight(),
          reason: e.key,
        );
        for (final b in blocks) {
          final fences = RegExp(
            r'^(```|~~~)',
            multiLine: true,
          ).allMatches(b).length;
          expect(
            fences.isEven,
            isTrue,
            reason: '${e.key}: an open fence in one block',
          );
        }
      }
      expect(splitReply(samples['paragraphs']!).length, greaterThan(3));
      expect(
        splitReply(samples['fenced code with blank lines']!).any(
          (b) =>
              b.contains('print(1);') &&
              b.contains('```dart') &&
              b.trimRight().endsWith('```'),
        ),
        isTrue,
      );
      final list = splitReply(samples['list item with a second paragraph']!);
      expect(
        list.any(
          (b) =>
              b.contains('项目一的第二段') && b.contains('项目一') && b.contains('项目二'),
        ),
        isTrue,
        reason: 'a list with a second paragraph stays in one block',
      );
    });

    test('a growing text only ever changes its last block', () {
      final text = samples['paragraphs']!;
      var previous = splitReply(text.substring(0, 800));
      for (var n = 801; n <= text.length; n += 17) {
        final now = splitReply(text.substring(0, n));
        for (var i = 0; i < previous.length - 1; i++) {
          expect(now[i], previous[i], reason: 'block $i at $n');
        }
        previous = now;
      }
    });
  });

  group('ReplyMarkdown looks like one MarkdownBody', () {
    for (final e in samples.entries) {
      testWidgets(e.key, (t) async {
        late MarkdownStyleSheet sheet;
        Widget whole() => Builder(
          builder: (context) {
            sheet = chatMarkdownStyle(context, 16);
            return MarkdownBody(
              styleSheet: sheet,
              builders: chatMarkdownBuilders(16),
              data: e.value,
            );
          },
        );
        await t.pumpWidget(host(whole()));
        final expected = t.getRect(find.byType(MarkdownBody).first);
        List<Rect> boxes() => [
          for (final type in [CodeBlock, Table, DecoratedBox])
            for (final w in find.byType(type).evaluate())
              t.getRect(find.byWidget(w.widget)),
        ];
        final wholeBoxes = boxes();
        final wholeTexts = [
          for (final w in find.byType(RichText).evaluate())
            t.getTopLeft(find.byWidget(w.widget)).dy,
        ];
        await t.pumpWidget(
          host(
            ReplyMarkdown(
              text: e.value,
              fontSize: 16,
              onTapLink: (_, _, _) {},
              imageBuilder: (_, _, _) => const SizedBox(),
            ),
          ),
        );
        final got = t.getRect(find.byType(ReplyMarkdown));
        expect(
          got.height,
          closeTo(expected.height, 0.5),
          reason: 'total height',
        );
        final texts = [
          for (final w in find.byType(RichText).evaluate())
            t.getTopLeft(find.byWidget(w.widget)).dy,
        ];
        final gotBoxes = boxes();
        expect(gotBoxes.length, wholeBoxes.length, reason: 'same boxes');
        for (var i = 0; i < gotBoxes.length; i++) {
          expect(
            gotBoxes[i].left,
            closeTo(wholeBoxes[i].left, 0.5),
            reason: 'box $i left',
          );
          expect(
            gotBoxes[i].width,
            closeTo(wholeBoxes[i].width, 0.5),
            reason: 'box $i width',
          );
          expect(
            gotBoxes[i].height,
            closeTo(wholeBoxes[i].height, 0.5),
            reason: 'box $i height',
          );
        }
        expect(
          texts.length,
          wholeTexts.length,
          reason: 'same number of text blocks',
        );
        for (var i = 0; i < texts.length; i++) {
          expect(texts[i], closeTo(wholeTexts[i], 0.5), reason: 'text $i top');
        }
      });
    }

    testWidgets(
      'finished blocks are not built again while the last one grows',
      (t) async {
        final text = samples['paragraphs']!;
        final notifier = ValueNotifier<String>(text.substring(0, 900));
        await t.pumpWidget(
          host(
            ValueListenableBuilder<String>(
              valueListenable: notifier,
              builder: (context, value, _) => ReplyMarkdown(
                text: value,
                fontSize: 16,
                onTapLink: (_, _, _) {},
                imageBuilder: (_, _, _) => const SizedBox(),
              ),
            ),
          ),
        );
        final first = find.byType(MarkdownBody).evaluate().first.widget;
        for (var n = 950; n < text.length; n += 60) {
          notifier.value = text.substring(0, n);
          await t.pump();
          expect(
            find.byType(MarkdownBody).evaluate().first.widget,
            same(first),
            reason: 'first block at $n',
          );
        }
      },
    );
  });

  testWidgets('opening and closing the drawer does not rebuild the messages', (
    t,
  ) async {
    await pumpHome(
      t,
      DuoLayout.none,
      size: const Size(402, 874),
      platform: TargetPlatform.iOS,
      seed: (c) {
        c.newConversation();
        for (var i = 0; i < 6; i++) {
          c.current.messages
            ..add(ChatMessage('user', '问题 $i'))
            ..add(ChatMessage('assistant', '回答 $i，有**加粗**。'));
        }
      },
    );
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(ReplyMarkdown), findsWidgets);
    final home = t.state(find.byType(JarvisHome)) as dynamic;
    var rebuilt = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is ReplyMarkdown) rebuilt++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    home.scaffold.currentState.openDrawer();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('新建会话'), findsWidgets, reason: 'the drawer opened');
    home.scaffold.currentState.closeDrawer();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(rebuilt, 0, reason: 'no message is rebuilt by the drawer');
  });

  testWidgets(
    'tapping a conversation in the drawer switches to it and then closes the drawer',
    (t) async {
      late String first, second;
      await pumpHome(
        t,
        DuoLayout.none,
        size: const Size(402, 874),
        platform: TargetPlatform.iOS,
        seed: (c) {
          c.newConversation();
          first = c.current.id;
          c.current.messages.add(ChatMessage('user', '第一个会话'));
          c.newConversation();
          second = c.current.id;
          c.current.messages.add(ChatMessage('user', '第二个会话'));
        },
      );
      await t.pump(const Duration(seconds: 1));
      final home = t.state(find.byType(JarvisHome)) as dynamic;
      for (final id in [first, second, second]) {
        home.scaffold.currentState.openDrawer();
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        await t.tap(find.byKey(ValueKey('conversation-surface-$id')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 600));
        expect(
          home.scaffold.currentState.isDrawerOpen,
          isFalse,
          reason: 'closed',
        );
        expect(home.widget.controller.selectedId, id);
      }
    },
  );
}
