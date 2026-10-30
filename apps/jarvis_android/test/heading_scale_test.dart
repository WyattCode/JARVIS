import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';

import 'b_chat_ui_test.dart' show pumpPhone;

void main() {
  for (final scale in [1.0, 1.3, 2.0, 2.4]) {
    testWidgets(
      'the chat header keeps the conversation name at text scale $scale',
      (t) async {
        t.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpPhone(
          t,
          size: const Size(375, 667),
          seed: (c) {
            c.current.title = '一个比较长的会话名称';
            c.current.messages.add(ChatMessage('user', '你好'));
          },
        );
        final line = find.byKey(const ValueKey('chat-heading-line'));
        final title = find.descendant(
          of: line,
          matching: find.text('一个比较长的会话名称'),
        );
        expect(title, findsOneWidget);
        // Several glyphs of the name stay, not a single one followed by an ellipsis.
        final paragraph = t.renderObject<RenderParagraph>(title);
        expect(t.getRect(title).width, greaterThan(60));
        expect(
          t.getRect(title).width,
          greaterThan(paragraph.textScaler.scale(12) * 4),
        );
        final name = t.renderObject<RenderParagraph>(
          find.descendant(of: line, matching: find.text('JARVIS')),
        );
        expect(name.didExceedMaxLines, isFalse);
        expect(t.getRect(line).right, lessThanOrEqualTo(375));
        expect(t.takeException(), isNull);
      },
    );
  }
}
