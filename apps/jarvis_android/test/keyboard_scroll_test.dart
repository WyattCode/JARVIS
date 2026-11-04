import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/follow_scroll.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'foldable_test.dart' show host;
import 'support.dart';

void main() {
  testWidgets(
    'Keyboard keeps historical reading fixed but pushes the followed tail',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await c.login('Wyatt', 'test');
      c.current.messages.addAll(
        List.generate(
          60,
          (i) => ChatMessage(
            i.isEven ? 'user' : 'assistant',
            '消息 $i：保持阅读内容与键盘一起移动。\n第二行内容。',
          ),
        ),
      );
      for (final size in [
        const Size(425, 623),
        const Size(400, 869),
        const Size(608, 860),
        const Size(860, 608),
      ]) {
        t.view.physicalSize = size;
        await t.pumpWidget(host(c));
        await t.pumpAndSettle();
        await t.pump();
        final list = find.descendant(
          of: find.byType(ChatPanel),
          matching: find.byType(ListView),
        );
        final scroll =
            t.widget<ListView>(list).controller! as FollowScrollController;
        await t.dragFrom(
          t.getTopRight(list) + const Offset(-8, 80),
          const Offset(0, 220),
        );
        await t.pumpAndSettle();
        final oldOffset = scroll.offset;
        final oldViewport = scroll.position.viewportDimension;
        expect(scroll.position.extentAfter, greaterThan(100));
        t.view.viewInsets = const FakeViewPadding(bottom: 250);
        await t.pump();
        await t.pump();
        final shift = oldViewport - scroll.position.viewportDimension;
        expect(shift, greaterThan(200));
        expect(
          scroll.offset,
          closeTo(oldOffset, 1),
          reason: '$size reading anchor',
        );
        t.view.viewInsets = FakeViewPadding.zero;
        await t.pump();
        await t.pump();
        expect(
          scroll.offset,
          closeTo(oldOffset, 1),
          reason: '$size keyboard close',
        );
        await t.dragFrom(
          t.getTopRight(list) + const Offset(-8, 80),
          const Offset(0, -2000),
        );
        await t.pumpAndSettle();
        expect(scroll.position.extentAfter, closeTo(0, 1));
        t.view.viewInsets = const FakeViewPadding(bottom: 250);
        await t.pump();
        await t.pump();
        expect(
          scroll.position.extentAfter,
          closeTo(0, 1),
          reason: '$size tail remains visible',
        );
        t.view.viewInsets = FakeViewPadding.zero;
        await t.pump();
        await t.pump();
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
