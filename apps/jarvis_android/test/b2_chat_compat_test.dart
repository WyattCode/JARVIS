import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'b2_support.dart';

/// The chat page on every straight iPhone: nothing overflows, nothing interactive sits under the Dynamic Island or the
/// home indicator, the primary controls are at least 44 pt, and the message list keeps room even with the keyboard up.
void main() {
  for (final device in straightPhones) {
    final landscape = device.size.width > device.size.height;
    for (final scale in [1.0, 1.5, 2.4]) {
      for (final typing in [false, true]) {
        final label =
            '${device.name} x$scale ${typing ? 'dark, messages, keyboard' : 'light, welcome'}';
        testWidgets(label, (t) async {
          final keyboard = typing ? (landscape ? 200.0 : 300.0) : 0.0;
          final c = await pumpDevice(
            t,
            device,
            scale: scale,
            dark: typing,
            keyboard: keyboard,
            seed: typing ? someMessages : null,
          );
          expect(t.takeException(), isNull);
          final safe = device.safe;
          final screen = Offset.zero & device.size;
          final usable = Rect.fromLTRB(
            safe.left,
            safe.top,
            device.size.width - safe.right,
            device.size.height - (keyboard > 0 ? keyboard : safe.bottom),
          );
          final controls = {
            'menu': find.byTooltip('展开会话'),
            'new chat': find.byTooltip('新建会话'),
            'more': find.byTooltip('更多操作'),
            'attach': find.byTooltip('添加附件'),
            'effort': find.byTooltip('选择思考深度'),
            'voice': find.byTooltip('语音对话').last,
            'input': find.byKey(const Key('chat-input')),
            'status': find.ancestor(
              of: find.byKey(const Key('connection-dot')),
              matching: find.byType(InkWell),
            ),
          };
          for (final entry in controls.entries) {
            if (entry.value.evaluate().isEmpty) continue;
            final rect = t.getRect(entry.value.first);
            expect(
              usable.contains(rect.topLeft) &&
                  usable.contains(rect.bottomRight - const Offset(.1, .1)),
              isTrue,
              reason: '${entry.key} $rect outside $usable',
            );
            if (entry.key != 'input' && entry.key != 'status') {
              // The hit area is the button around the tooltip's child (a padded button is bigger than its icon box).
              final button = find.ancestor(
                of: entry.value.first,
                matching: find.byWidgetPredicate(
                  (w) => w is IconButton || w is InkWell,
                ),
              );
              final hit = button.evaluate().isEmpty
                  ? rect
                  : t.getRect(button.first);
              expect(
                hit.width >= 44 && hit.height >= 44,
                isTrue,
                reason: '${entry.key} is ${hit.size}',
              );
            }
            if (entry.key == 'status') {
              expect(rect.height, greaterThanOrEqualTo(44));
            }
          }
          // The welcome cards: tall enough to hit, inside the island's side margins.
          if (!typing) {
            for (var i = 0; i < 4; i++) {
              final card = find.byKey(ValueKey('starter-$i'));
              if (card.evaluate().isEmpty) continue;
              final rect = t.getRect(card);
              if (rect.height < 1) continue;
              expect(rect.left, greaterThanOrEqualTo(safe.left));
              expect(
                rect.right,
                lessThanOrEqualTo(device.size.width - safe.right),
              );
            }
          }
          // With the keyboard up the messages keep a strip of their own.
          if (typing) {
            final list = t.getRect(find.byType(ListView).first);
            expect(
              list.height,
              greaterThanOrEqualTo(landscape ? 50 : 120),
              reason: 'list $list',
            );
          }
          // Landscape: the column is centred and readable (not stretched across 956 pt).
          if (!typing) {
            final frame = t.getRect(find.byKey(const Key('composer-frame')));
            expect(frame.center.dx, closeTo(usable.center.dx, 1));
            expect(frame.width, lessThanOrEqualTo(usable.width));
          }
          expect(
            screen.contains(
              t.getRect(find.byKey(const Key('composer-frame'))).bottomRight,
            ),
            isTrue,
          );
          c.voice.hashCode;
          await t.pump(const Duration(seconds: 2));
        });
      }
    }
  }
}
