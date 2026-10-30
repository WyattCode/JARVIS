import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/ui/duo_layout.dart';

import 'b2_support.dart';
import 'b_chat_ui_test.dart' show halfFolded;
import 'duo_rail_test.dart' show duoLandscape, duoOuter, pumpHome;

void main() {
  testWidgets(
    'copy and regenerate: each icon centre taps only its own button',
    (t) async {
      final copied = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
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
      await pumpHome(
        t,
        duoLandscape,
        seed: (c) => c.current.messages
          ..add(ChatMessage('user', '你好'))
          ..add(ChatMessage('assistant', '回复内容')),
      );
      final copy = t.getRect(find.byTooltip('复制回复'));
      final regenerate = t.getRect(find.byTooltip('重新生成'));
      // The two tap areas meet; the icons keep their small gap, and the neighbour never takes the other's tap.
      expect(copy.right, lessThanOrEqualTo(regenerate.left + .5));
      expect(regenerate.width, greaterThanOrEqualTo(44));
      await t.tapAt(Offset(copy.left + 8, copy.center.dy));
      await t.pump();
      expect(copied, ['回复内容']);
      copied.clear();
      await t.tapAt(Offset(regenerate.left + 9, regenerate.center.dy));
      await t.pump();
      expect(copied, isEmpty);
      await t.pump(const Duration(seconds: 2));
    },
  );

  group('welcome cards show their whole description', () {
    for (final entry in {
      'half-folded': (halfFolded, const Size(951, 669)),
      'outer display': (duoOuter, const Size(466, 678)),
      'unfolded': (duoLandscape, const Size(951, 669)),
    }.entries) {
      for (final scale in [1.0, 1.5]) {
        testWidgets('${entry.key} x$scale', (t) async {
          t.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
          final c = await pumpHome(t, entry.value.$1, size: entry.value.$2);
          for (final starter in c.starters) {
            final paragraph = t.renderObject<RenderParagraph>(
              find.text(starter.description!),
            );
            expect(
              paragraph.didExceedMaxLines,
              isFalse,
              reason: starter.description,
            );
          }
          expect(t.takeException(), isNull);
        });
      }
    }
  });

  group('sidebar grip', () {
    testWidgets('does not cover message text half-folded', (t) async {
      await pumpHome(t, halfFolded, seed: someMessages);
      final grip = t.getRect(find.byKey(const Key('pane-grip')));
      final texts = rectsOf(
        t,
        find.descendant(
          of: find.byType(ListView).last,
          matching: find.byType(RichText),
        ),
      );
      for (final text in texts) {
        expect(text.overlaps(grip), isFalse, reason: '$text vs $grip');
      }
    });

    testWidgets('does not cover message text on a docked tablet', (t) async {
      final c = await pumpHome(
        t,
        DuoLayout.none,
        size: const Size(1024, 768),
        insets: EdgeInsets.zero,
        seed: someMessages,
      );
      final grip = t.getRect(find.byKey(const Key('pane-grip')));
      final reply = t.getRect(
        find.byKey(
          ValueKey('bubble-${c.current.id}-${c.current.messages.last.id}'),
        ),
      );
      expect(reply.left, greaterThanOrEqualTo(grip.right));
    });
  });
}
