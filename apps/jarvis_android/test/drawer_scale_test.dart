import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';

import 'b_chat_ui_test.dart' show openDrawer, pumpPhone;

void main() {
  for (final scale in [1.0, 1.3, 2.0, 2.4]) {
    testWidgets('the phone drawer keeps readable rows at text scale $scale', (
      t,
    ) async {
      t.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPhone(
        t,
        size: const Size(375, 667),
        seed: (c) {
          for (var i = 0; i < 7; i++) {
            c.newConversation().title = '会话标题 $i';
            c.current.messages.add(ChatMessage('user', '你好 $i'));
          }
        },
      );
      await openDrawer(t);
      Finder inDrawer(Finder f) =>
          find.descendant(of: find.byType(Drawer), matching: f);
      final drawer = t.getRect(find.byType(Drawer));
      expect(drawer.width, lessThanOrEqualTo(375 * .85 + .01));
      expect(drawer.width, greaterThanOrEqualTo(243));
      if (scale >= 2) expect(drawer.width, greaterThan(300));
      // Brand, search hint and a row title are whole, not cut to a few glyphs.
      for (final text in ['JARVIS', '搜索会话', '会话标题 3']) {
        final finder = inDrawer(find.text(text));
        expect(finder, findsWidgets, reason: text);
        final paragraph = t.renderObject<RenderParagraph>(finder.first);
        expect(paragraph.didExceedMaxLines, isFalse, reason: text);
      }
      final title = t.getRect(inDrawer(find.text('会话标题 3')).first);
      expect(title.width, greaterThan(80));
      expect(title.right, lessThanOrEqualTo(drawer.right));
      expect(t.takeException(), isNull);
    });
  }
}
