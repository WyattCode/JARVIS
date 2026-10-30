import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

void main() {
  ScrollPosition chatPosition(WidgetTester t) => t
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const PageStorageKey('messages-p')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  Future<JarvisController> longChat(WidgetTester t) async {
    t.view.devicePixelRatio = 3;
    t.view.physicalSize = const Size(1179, 2556);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    addTearDown(c.dispose);
    c.conversations.clear();
    c.conversations.add(Conversation('p', title: 'probe'));
    c.selectedId = 'p';
    for (var i = 0; i < 40; i++) {
      c.current.messages.add(ChatMessage('user', '问题 $i'));
      final body = StringBuffer('## 标题 $i\n\n');
      for (var k = 0; k < 3 + i % 5; k++) {
        body.write('这是第 $k 段很长的回答内容，用来撑出不同的高度。' * (2 + k % 3));
        body.write('\n\n- 要点一\n- 要点二\n\n');
      }
      c.current.messages.add(ChatMessage('assistant', body.toString()));
    }
    await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
    await t.pump(const Duration(milliseconds: 300));
    return c;
  }

  // Selectable text owns a one-line scroller; it must never inherit the chat list's offset.
  Iterable<ScrollPosition> textScrollers(WidgetTester t) => find
      .byType(Scrollable)
      .evaluate()
      .where((e) => e.findAncestorWidgetOfExactType<EditableText>() != null)
      .map((e) => ((e as StatefulElement).state as ScrollableState).position);

  testWidgets('older replies do not slide in while scrolling up', (t) async {
    await longChat(t);
    final drag = await t.startGesture(const Offset(200, 600));
    for (var f = 0; f < 60; f++) {
      await drag.moveBy(const Offset(0, 80));
      await t.pump(const Duration(milliseconds: 16));
      for (final p in textScrollers(t)) {
        expect(p.pixels, 0, reason: '回复文字不能带着列表的滚动位置出现');
        expect(p.isScrollingNotifier.value, isFalse);
      }
    }
    await drag.up();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a swipe that starts on reply text scrolls the chat', (t) async {
    final c = await longChat(t);
    final last = c.current.messages.last;
    for (var k = 0; k < 40; k++) {
      last.text += '流式追加的新文字 $k。\n\n';
      c.notifyListeners();
      await t.pump(const Duration(milliseconds: 32));
    }
    await t.pump();
    final position = chatPosition(t);
    final start = position.pixels;
    final drag = await t.startGesture(const Offset(200, 300));
    for (var f = 0; f < 8; f++) {
      await drag.moveBy(const Offset(0, 60));
      await t.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    expect(start - position.pixels, greaterThan(300));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
