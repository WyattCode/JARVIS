import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/conversation_rows.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/sidebar_list.dart';

import 'support.dart';

/// The conversation list, as the iOS app has it.
void main() {
  /// A conversation last active [days] days ago (the clock is in its ids).
  Conversation at(String title, {int days = 0, DateTime? now}) {
    final when = (now ?? DateTime(2026, 11, 8, 12)).subtract(
      Duration(days: days),
    );
    return Conversation(
      '${when.microsecondsSinceEpoch}-0',
      title: title,
      messages: [
        ChatMessage(
          'user',
          '正文 $title',
          id: '${when.microsecondsSinceEpoch}-1',
        ),
      ],
    );
  }

  group('the rows', () {
    final now = DateTime(2026, 11, 8, 12);
    test('one group of days has no headings', () {
      final r = ConversationRows.rows([at('甲'), at('乙')], now: now);
      expect(r.rows.where((x) => x.isHeader), isEmpty);
      expect(r.found, 2);
    });

    test('more than one group gets 今天 / 昨天 / 更早 between them', () {
      final r = ConversationRows.rows([
        at('甲'),
        at('乙', days: 1),
        at('丙', days: 9),
      ], now: now);
      expect(r.rows.map((x) => x.title), ['今天', '甲', '昨天', '乙', '更早', '丙']);
      expect(r.rows.where((x) => x.isHeader).length, 3);
    });

    test('a conversation whose ids are not clocks is 更早', () {
      final r = ConversationRows.rows([
        at('甲'),
        Conversation('abc', title: '无时钟'),
      ], now: now);
      expect(r.rows.map((x) => x.title), ['今天', '甲', '更早', '无时钟']);
    });

    test('a search matches the title or any message', () {
      final all = [at('周报'), at('旅行计划')];
      expect(ConversationRows.rows(all, query: '周', now: now).found, 1);
      expect(ConversationRows.rows(all, query: '正文 旅行', now: now).found, 1);
      expect(ConversationRows.rows(all, query: '没有', now: now).found, 0);
      expect(ConversationRows.rows(all, query: '  ', now: now).found, 2);
    });

    test('the open one and the generating one are marked', () {
      final all = [at('甲'), at('乙')];
      final r = ConversationRows.rows(
        all,
        selected: all[1].id,
        generating: (id) => id == all[0].id,
        now: now,
      );
      expect(r.rows[0].generating, isTrue);
      expect(r.rows[1].selected, isTrue);
    });
  });

  group('the list', () {
    Future<JarvisController> controller(int count) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.conversations.clear();
      for (var i = 0; i < count; i++) {
        c.conversations.add(Conversation('row-$i', title: '会话 $i'));
      }
      c.selectedId = 'row-0';
      return c;
    }

    Future<List<String>> shown(
      WidgetTester t,
      JarvisController c,
      SidebarMode mode, {
      List<String>? calls,
    }) async {
      final seen = calls ?? <String>[];
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (context, _) => ConversationSidebar(
                controller: c,
                mode: mode,
                onChoose: () => seen.add('choose'),
                onNew: () => seen.add('new'),
                onSettings: () => seen.add('settings'),
                onRename: (id, title) => seen.add('rename $id'),
                onDelete: (id) => seen.add('delete $id'),
                onClose: mode == SidebarMode.drawer
                    ? null
                    : () => seen.add('close'),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      return seen;
    }

    testWidgets('a drawer has the brand and the 最近 heading, and no bar', (
      t,
    ) async {
      final c = await controller(3);
      await shown(t, c, SidebarMode.drawer);
      expect(find.byKey(const ValueKey('sidebar-brand-row')), findsOneWidget);
      expect(find.text('最近'), findsOneWidget);
      expect(find.byKey(const Key('new-conversation')), findsNothing);
      expect(find.byKey(const Key('sidebar-settings')), findsNothing);
      // No search below six conversations, no wide button, no settings row.
      expect(find.byKey(const Key('sidebar-search')), findsNothing);
      expect(find.text('设置'), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('a docked list has the bar: close, new, search', (t) async {
      final c = await controller(3);
      final seen = await shown(t, c, SidebarMode.docked);
      await t.tap(find.byKey(const Key('new-conversation')));
      await t.tap(find.byKey(const Key('close-conversation-page')));
      expect(seen, ['new', 'close']);
      expect(find.byKey(const Key('sidebar-settings')), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('a page of its own also has the settings', (t) async {
      final c = await controller(3);
      final seen = await shown(t, c, SidebarMode.page);
      await t.tap(find.byKey(const Key('sidebar-settings')));
      expect(seen, ['settings']);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('rows are 58 high and choosing one opens it', (t) async {
      final c = await controller(3);
      final seen = await shown(t, c, SidebarMode.drawer);
      expect(
        t
            .getSize(find.byKey(const ValueKey('conversation-surface-row-1')))
            .height,
        58,
      );
      await t.tap(find.text('会话 1'));
      await t.pump();
      expect(c.selectedId, 'row-1');
      expect(seen, ['choose']);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('from six conversations on there is a search that filters', (
      t,
    ) async {
      final c = await controller(7);
      await shown(t, c, SidebarMode.drawer);
      expect(find.byKey(const Key('sidebar-search')), findsOneWidget);
      await t.enterText(find.byKey(const Key('sidebar-search')), '会话 3');
      await t.pump();
      final list = find.byKey(const Key('conversation-list'));
      expect(
        find.descendant(of: list, matching: find.text('会话 3')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: list, matching: find.text('会话 4')),
        findsNothing,
      );
      await t.enterText(find.byKey(const Key('sidebar-search')), '不存在');
      await t.pump();
      expect(find.text('没有匹配的会话'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets(
      'the bar\'s search button brings the field in and takes it away',
      (t) async {
        final c = await controller(3);
        await shown(t, c, SidebarMode.docked);
        expect(find.byKey(const Key('sidebar-search')), findsNothing);
        await t.tap(find.byKey(const Key('sidebar-search-button')));
        await t.pump();
        expect(find.byKey(const Key('sidebar-search')), findsOneWidget);
        await t.tap(find.byKey(const Key('sidebar-search-button')));
        await t.pump();
        expect(find.byKey(const Key('sidebar-search')), findsNothing);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      },
    );

    testWidgets('a held row offers rename and delete, and delete asks first', (
      t,
    ) async {
      final c = await controller(3);
      final seen = await shown(t, c, SidebarMode.drawer);
      await openConversationMenu(t, index: 1);
      expect(find.text('重命名'), findsOneWidget);
      await t.tap(find.text('重命名'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(seen, ['rename row-1']);

      await openConversationMenu(t, index: 1);
      await t.tap(find.text('删除'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      // Nothing is deleted until it is confirmed.
      expect(seen, ['rename row-1']);
      expect(find.textContaining('会从这台设备上删除，此操作无法撤销。'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(seen, ['rename row-1']);

      await deleteConversationViaMenu(t, index: 1);
      expect(seen, ['rename row-1', 'delete row-1']);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('the day sections are the headings when there are some', (
      t,
    ) async {
      final c = await controller(0);
      c.conversations.addAll([
        at('今天的', days: 0, now: DateTime.now()),
        at('以前的', days: 10, now: DateTime.now()),
      ]);
      c.selectedId = c.conversations.first.id;
      await shown(t, c, SidebarMode.drawer);
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('更早'), findsOneWidget);
      expect(find.text('最近'), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  });
}
