import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'b2_support.dart';
import 'b3_support.dart';

const _se = Device(
  'SE portrait',
  Size(375, 667),
  safe: EdgeInsets.only(top: 20),
);

void main() {
  void attachments(JarvisController c, int n) {
    connected(c);
    for (var i = 0; i < n; i++) {
      c.current.pendingAttachments.add(
        Attachment(
          id: 'a$i',
          name: 'IMG_$i.jpg',
          mime: 'image/jpeg',
          kind: 'file',
          size: 100,
        ),
      );
    }
  }

  group('composer chrome counts against the field budget', () {
    for (final (scale, count, offline, error) in [
      (2.4, 0, true, true),
      (2.4, 1, true, true),
      (2.0, 4, false, true),
      (2.4, 4, true, true),
      (1.0, 4, true, true),
    ]) {
      testWidgets(
        'SE keyboard 336 x$scale, $count attachments, offline=$offline, error=$error',
        (t) async {
          final c = await pumpWired(
            t,
            _se,
            keyboard: 336,
            scale: scale,
            offline: () => offline,
            seed: (c) {
              attachments(c, count);
              c.setDraft('你好');
              if (error) {
                c.error = '这是一条比较长的错误提示，用来占用多行的空间。' * 3;
              }
            },
          );
          await t.pump(const Duration(milliseconds: 400));
          expect(t.takeException(), isNull);
          final send = find.byTooltip('发送');
          expect(send, findsOneWidget);
          final bottom = t.getRect(send).bottom;
          expect(bottom, lessThanOrEqualTo(667 - 336 + .5));
          expect(c.current.draft, '你好');
        },
      );
    }

    testWidgets(
      'a long draft still leaves the send button above the keyboard',
      (t) async {
        await pumpWired(
          t,
          const Device(
            '400x667',
            Size(400, 667),
            safe: EdgeInsets.only(top: 20),
          ),
          keyboard: 336,
          scale: 2.4,
          offline: () => true,
          seed: (c) {
            attachments(c, 2);
            c.setDraft(List.filled(9, '很长的一段草稿').join('\n'));
            c.error = '出错了：' * 30;
          },
        );
        expect(t.takeException(), isNull);
        expect(
          t.getRect(find.byTooltip('发送')).bottom,
          lessThanOrEqualTo(331.5),
        );
        await t.pump(const Duration(seconds: 1));
      },
    );

    testWidgets('with room the bars all stay; when tight the offline bar steps '
        'aside and the error keeps to one line', (t) async {
      void seed(JarvisController c) {
        connected(c);
        c.setDraft('你好');
        c.error = '出错了：' * 30;
      }

      await pumpWired(t, _se, offline: () => true, seed: seed);
      expect(find.byKey(const Key('offline-bar')), findsOneWidget);
      expect(
        t
            .widget<Text>(
              find.descendant(
                of: find.byKey(const Key('error-line')),
                matching: find.byType(Text),
              ),
            )
            .maxLines,
        3,
      );
      expect(t.takeException(), isNull);

      await pumpWired(
        t,
        _se,
        keyboard: 336,
        scale: 2.4,
        offline: () => true,
        seed: seed,
      );
      expect(find.byKey(const Key('offline-bar')), findsNothing);
      expect(
        t
            .widget<Text>(
              find.descendant(
                of: find.byKey(const Key('error-line')),
                matching: find.byType(Text),
              ),
            )
            .maxLines,
        1,
      );
      expect(t.takeException(), isNull);
      await t.pump(const Duration(seconds: 1));
    });
  });
}
