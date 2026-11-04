import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/voice_page.dart';

import 'voice_support.dart';

import '../test/support.dart';

void window(WidgetTester t) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(623, 425);
  t.view.viewPadding = const FakeViewPadding(top: 46, bottom: 20);
  t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetViewPadding);
  addTearDown(t.view.resetPadding);
  addTearDown(t.view.resetViewInsets);
}

void keyboard(WidgetTester t, double h) {
  t.view.viewInsets = FakeViewPadding(bottom: h);
  t.view.padding = FakeViewPadding(top: 46, bottom: h > 0 ? 0 : 20);
}

void main() {
  testWidgets(
    'Short landscape completion is an input-row entry and keeps the draft',
    (t) async {
      window(t);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final input = find.byKey(const Key('chat-input'));
      await t.tap(input);
      await t.enterText(input, '保留草稿');
      keyboard(t, 320);
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      c.current.tasks.add(
        MediaTask(
          id: 'ready',
          kind: 'video',
          prompt: '完成',
          args: {},
          status: 'completed',
          urls: ['https://example.test/a.mp4'],
        ),
      );
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 200));
      await t.pump();
      await t.pump();
      final notice = find.byKey(const Key('completed-work-notice'));
      expect(notice.hitTestable(), findsOneWidget);
      final n = t.getRect(notice),
          frame = t.getRect(find.byKey(const Key('composer-frame')));
      expect(n.top, greaterThanOrEqualTo(46));
      expect(n.bottom, lessThanOrEqualTo(105));
      expect(n.left, greaterThanOrEqualTo(frame.left));
      expect(n.right, lessThanOrEqualTo(frame.right));
      expect(c.current.draft, '保留草稿');
      expect(
        t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
        true,
      );
      await t.tap(notice);
      keyboard(t, 0);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('生成作品'), findsOneWidget);
      expect(c.current.draft, '保留草稿');
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'Taller landscape IME has a scroll fallback without losing input state',
    (t) async {
      window(t);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final input = find.byKey(const Key('chat-input'));
      await t.tap(input);
      await t.enterText(input, '极短窗口');
      final state = t.state(find.byType(EditableText));
      keyboard(t, 340);
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      expect(t.takeException(), isNull);
      expect(c.current.draft, '极短窗口');
      expect(t.state(find.byType(EditableText)), same(state));
      final scroll = Scrollable.of(
        t.element(find.byKey(const Key('composer-frame'))),
      ).position;
      expect(scroll.maxScrollExtent, greaterThan(0));
      expect(
        t.getRect(find.byKey(const Key('composer-frame'))).bottom,
        lessThanOrEqualTo(85),
      );
      keyboard(t, 0);
      await t.pump();
      await t.pump();
      expect(c.current.draft, '极短窗口');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'Compact attachment entry previews and removes the chosen attachment',
    (t) async {
      window(t);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.current.pendingAttachments.add(
        Attachment(
          id: 'file',
          name: '检查附件.txt',
          mime: 'text/plain',
          kind: 'document',
          text: '文件预览内容',
          size: 18,
        ),
      );
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      await t.tap(find.byKey(const Key('chat-input')));
      await t.enterText(find.byKey(const Key('chat-input')), '附件草稿');
      keyboard(t, 320);
      await t.pump();
      await t.tap(find.byTooltip('管理已选附件'));
      keyboard(t, 0);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('已选附件'), findsOneWidget);
      expect(find.byKey(const ValueKey('selected-file')), findsOneWidget);
      await t.tap(
        find.descendant(
          of: find.byKey(const ValueKey('selected-file')),
          matching: find.text('检查附件.txt'),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('文件预览内容'), findsOneWidget);
      await t.tap(find.text('关闭'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(
        find.descendant(
          of: find.byKey(const ValueKey('selected-file')),
          matching: find.byTooltip('移除 检查附件.txt'),
        ),
      );
      await t.pump();
      expect(c.current.pendingAttachments, isEmpty);
      expect(find.text('没有已选附件'), findsOneWidget);
      expect(c.current.draft, '附件草稿');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'Large-font portrait scroll cue disappears at the final suggestion row',
    (t) async {
      window(t);
      t.view.physicalSize = const Size(425, 623);

      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: JarvisHome(controller: c),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('welcome-more-cue')), findsOneWidget);
      final scroll = Scrollable.of(
        t.element(find.byKey(const ValueKey('starter-0'))),
      ).position;
      scroll.jumpTo(scroll.maxScrollExtent);
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('welcome-more-cue')), findsNothing);
      expect(
        find.byKey(const ValueKey('starter-3')).hitTestable(),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Multiline drafts and loading attachments fit all short keyboard budgets',
    (t) async {
      window(t);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.current.pendingAttachments.add(
        Attachment(
          id: 'file',
          name: '多行.txt',
          mime: 'text/plain',
          kind: 'document',
          text: '正文',
          size: 6,
        ),
      );
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final input = find.byKey(const Key('chat-input'));
      await t.tap(input);
      await t.enterText(input, List.filled(20, '多行草稿保留').join('\n'));
      c.beginAttachment(c.current);
      for (final height in [120.0, 180.0, 220.0, 260.0, 320.0, 340.0]) {
        keyboard(t, height);
        await t.pump();
        await t.pump(const Duration(milliseconds: 100));
        expect(t.takeException(), isNull, reason: 'IME $height');
        expect(c.current.draft, contains('多行草稿保留'));
        expect(
          t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
          true,
        );
      }
      c.endAttachment(c.current);
      await t.pump();
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Inner and outer call controls share the two-percent safe-area inset',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewPadding);
      for (final size in [
        const Size(425, 623),
        const Size(623, 425),
        const Size(608, 860),
        const Size(860, 608),
      ]) {
        t.view.physicalSize = size;
        for (final side in [0.0, 16.0]) {
          t.view.padding = FakeViewPadding(left: side, right: side);
          t.view.viewPadding = FakeViewPadding(left: side, right: side);
          final c = JarvisController(
            FakeApi(),
            MemoryVault(),
            audioDevice: FakeAudio(),
          );
          await c.initialize();
          c.voice.owner = c.current;
          c.voice.open = true;
          c.voice.ready = true;
          c.voice.status = '已就绪';
          await t.pumpWidget(MaterialApp(home: VoicePage(controller: c)));
          await t.pump();
          final left = t.getRect(find.byTooltip('收起通话界面'));
          final right = t.getRect(find.byTooltip('结束语音通话'));
          final expected = side + (size.width - 2 * side) * .02 + 4;
          expect(left.left, closeTo(expected, .1), reason: '$size side $side');
          expect(size.width - right.right, closeTo(expected, .1));
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
          c.dispose();
        }
      }
    },
  );
}
