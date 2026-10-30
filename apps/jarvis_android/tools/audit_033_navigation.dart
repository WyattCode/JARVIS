import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/follow_scroll.dart';

import '../test/support.dart';
import '../test/foldable_test.dart' show host;

void main() {
  testWidgets('Audit Android menu Back and history send behavior', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(860, 608);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await c.login('Audit', 'test');
    c.current.messages.addAll(
      List.generate(
        40,
        (i) => ChatMessage(
          i.isEven ? 'user' : 'assistant',
          '消息$i\n用于保持历史阅读位置。\n测试文本。',
        ),
      ),
    );
    await t.pumpWidget(host(c));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('会话操作').first);
    await t.pumpAndSettle();
    final nav = Navigator.of(t.element(find.byType(JarvisHome)));
    final handled = await nav.maybePop();
    await t.pumpAndSettle();
    final menuRemains = find
        .widgetWithText(MenuItemButton, '重命名')
        .evaluate()
        .isNotEmpty;
    if (menuRemains) {
      await t.tapAt(const Offset(650, 300));
      await t.pumpAndSettle();
    }
    final list = find.descendant(
      of: find.byType(ChatPanel),
      matching: find.byType(ListView),
    );
    final scroll =
        t.widget<ListView>(list).controller! as FollowScrollController;
    await t.drag(list, const Offset(0, 300));
    await t.pumpAndSettle();
    final oldOffset = scroll.offset;
    c.current.messages.add(ChatMessage('user', '新的提问'));
    c.notifyDraftSuggestion();
    await t.pump();
    await t.pump();
    final notes = {
      'back_handled': handled,
      'menu_remains_after_back': menuRemains,
      'reading_offset': oldOffset,
      'after_send_offset': scroll.offset,
      'after_send_remaining': scroll.position.extentAfter,
    };
    final out = Directory(
      Platform.environment['JARVIS_NAV_AUDIT_DIR'] ??
          '/home/user/.local/state/jarvis-audit-032-current',
    )..createSync(recursive: true);
    File('${out.path}/navigation.json').writeAsStringSync(jsonEncode(notes));
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
