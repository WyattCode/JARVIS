import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/starters.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

void main() {
  test('Shared starter copy follows the clock and model capabilities', () {
    expect(timeGreeting(DateTime(2026, 10, 27, 4)), '还没休息吗？');
    expect(timeGreeting(DateTime(2026, 10, 27, 5)), '早上好');
    expect(timeGreeting(DateTime(2026, 10, 27, 12)), '下午好');
    expect(timeGreeting(DateTime(2026, 10, 27, 18)), '晚上好');
    for (final group in starterGroups) {
      for (final s in group) {
        expect(s.description, isNotEmpty);
      }
    }
    final session = SessionStarters();
    expect(
      session.available((_) => false).every((s) => s.requires == null),
      isTrue,
    );
    expect(session.available((_) => true), session.available((_) => true));
  });

  testWidgets(
    'Android cards retain their prompt and fit cover, inner and tall windows',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      for (final size in [
        const Size(360, 560),
        const Size(425, 623),
        const Size(608, 860),
        const Size(860, 608),
        const Size(400, 900),
      ]) {
        t.view.physicalSize = size;
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
        await t.pump();
        final first = find.byKey(const ValueKey('starter-0'));
        await t.ensureVisible(first);
        await t.tap(first);
        await t.pump();
        expect(c.current.draft, c.starters.first.prompt);
        expect(find.text(c.starters.first.description!), findsOneWidget);
        expect(t.takeException(), isNull, reason: '$size');
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );

  testWidgets(
    'Deleting from the menu asks first, Undo restores and the sidebar notice expires',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final victim = c.current;
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      await deleteConversationViaMenu(t);
      expect(c.conversations, isNot(contains(victim)));
      expect(find.text('会话已删除'), findsOneWidget);
      final note = t.getRect(find.byKey(const Key('sidebar-notice')));
      expect(
        note.right,
        lessThanOrEqualTo(
          t.getRect(find.byKey(const Key('docked-sidebar'))).right,
        ),
      );
      await t.tap(find.text('撤销'));
      await t.pump();
      expect(c.conversations, contains(victim));
      expect(find.text('会话已删除'), findsNothing);
      await deleteConversationViaMenu(t);
      await t.pump(const Duration(milliseconds: 650));
      await t.pump(const Duration(milliseconds: 350));
      await t.pump(const Duration(seconds: 3));
      expect(find.text('会话已删除'), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets('A generating conversation cannot be deleted and keeps its row', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(860, 608);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await c.login('test', 'fake');
    final victim = c.current;
    c.setDraft('still running');
    final sending = c.send();
    await t.pump();
    await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
    await t.pump();
    expect(c.canDeleteConversation(victim.id), isFalse);
    final row = find.byKey(ValueKey('conversation-surface-${victim.id}'));
    // It is told at once, without asking first and then refusing.
    await openConversationMenu(t);
    await t.tap(find.text('删除'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('confirm-delete')), findsNothing);
    expect(c.conversations, contains(victim));
    expect(row, findsOneWidget);
    expect(find.text('请先结束此会话的任务或通话，再删除会话'), findsOneWidget);
    c.cancel(victim.id);
    await sending;
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Cover rename dialog stays inside the viewport with keyboard', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(425, 623);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetViewInsets);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
    await t.pump();
    await t.tap(find.byTooltip('展开会话'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await openConversationMenu(t);
    await t.tap(find.text('重命名'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    t.view.viewInsets = const FakeViewPadding(bottom: 250);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final save = find.text('保存');
    await t.ensureVisible(save);
    final rect = t.getRect(save);
    expect(rect.bottom, lessThanOrEqualTo(373));
    await t.enterText(find.byKey(const Key('rename-field')), '新的会话名称');
    await t.tap(save);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(c.current.title, '新的会话名称');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
