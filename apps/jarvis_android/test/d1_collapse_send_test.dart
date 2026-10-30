import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/motion.dart';

import 'b_chat_ui_test.dart' show pumpPhone;
import 'duo_rail_test.dart' show duoOuter, pumpHome;

void main() {
  group('collapse follows the incoming child at once', () {
    Widget host(bool tall, {required bool overlay, bool reduce = false}) =>
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                SmoothSize(
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: reduce
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    layoutBuilder: overlay
                        ? overlayOutgoing()
                        : AnimatedSwitcher.defaultLayoutBuilder,
                    child: tall
                        ? const SizedBox(
                            key: ValueKey('tall'),
                            width: 100,
                            height: 100,
                          )
                        : const SizedBox(
                            key: ValueKey('short'),
                            width: double.infinity,
                          ),
                  ),
                ),
              ],
            ),
          ),
        );

    Future<List<double>> heights(
      WidgetTester t, {
      required bool overlay,
    }) async {
      await t.pumpWidget(host(true, overlay: overlay));
      await t.pumpWidget(host(false, overlay: overlay));
      final out = <double>[];
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 16));
        out.add(t.getSize(find.byType(SmoothSize)).height);
      }
      await t.pump(const Duration(milliseconds: 500));
      return out;
    }

    testWidgets('the height shrinks from the first frames', (t) async {
      final h = await heights(t, overlay: true);
      expect(h.first, lessThan(100), reason: '$h');
      expect(h[2], lessThan(60), reason: '$h');
      for (var i = 1; i < h.length; i++) {
        expect(h[i], lessThanOrEqualTo(h[i - 1]), reason: '$h');
      }
      expect(t.getSize(find.byType(SmoothSize)).height, 0);
      expect(t.takeException(), isNull);
    });

    testWidgets('control: the default layout waits for the fade-out', (
      t,
    ) async {
      final h = await heights(t, overlay: false);
      // Frames 0-8 are within the 150ms fade: the stack is still as tall as the outgoing child.
      expect(h[5], 100, reason: '$h');
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('with Reduce Motion it collapses at once and does not throw', (
      t,
    ) async {
      await t.pumpWidget(host(true, overlay: true, reduce: true));
      await t.pumpWidget(host(false, overlay: true, reduce: true));
      await t.pump();
      expect(t.getSize(find.byType(SmoothSize)).height, 0);
      expect(t.takeException(), isNull);
    });
  });

  group('the composer cluster collapses with its fade', () {
    testWidgets('side mic leaving narrows the cluster in the first frames', (
      t,
    ) async {
      await pumpPhone(t);
      Finder cluster() => find.descendant(
        of: find.byKey(const Key('composer-frame')),
        matching: find.ancestor(
          of: find.byType(IconButton).last,
          matching: find.byType(AnimatedSize),
        ),
      );
      await t.enterText(find.byKey(const Key('chat-input')), '你好');
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final wide = t.getSize(cluster().first).width;
      await t.enterText(find.byKey(const Key('chat-input')), '');
      await t.pump();
      final widths = <double>[];
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 16));
        widths.add(t.getSize(cluster().first).width);
      }
      expect(widths[2], lessThan(wide - 10), reason: '$wide $widths');
      await t.pump(const Duration(seconds: 1));
      expect(t.getSize(cluster().first).width, lessThan(wide - 30));
      expect(t.takeException(), isNull);
    });
  });

  group('send button keeps its size from empty to typed', () {
    for (final entry in {
      'tall phone': () => (null, const Size(400, 800)),
      'foldable outer display': () => (duoOuter, const Size(466, 678)),
    }.entries) {
      testWidgets(entry.key, (t) async {
        final (layout, size) = entry.value();
        if (layout == null) {
          await pumpPhone(t, size: size);
        } else {
          await pumpHome(t, layout, size: size);
        }
        // The send / microphone button is the last button of the composer (the side microphone comes before it).
        Size button() => t.getSize(
          find
              .descendant(
                of: find
                    .descendant(
                      of: find.byKey(const Key('composer-frame')),
                      matching: find.byType(IconButton),
                    )
                    .last,
                matching: find.byType(Material),
              )
              .first,
        );
        final empty = button();
        await t.enterText(find.byKey(const Key('chat-input')), '你');
        await t.pump();
        for (var i = 0; i < 24; i++) {
          expect(button(), empty, reason: 'frame $i');
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
        expect(button(), empty);
        await t.enterText(find.byKey(const Key('chat-input')), '');
        await t.pump();
        for (var i = 0; i < 24; i++) {
          await t.pump(const Duration(milliseconds: 16));
          expect(button(), empty, reason: 'back, frame $i');
        }
        // The draft is saved half a second after the last change.
        await t.pump(const Duration(seconds: 1));
        expect(t.takeException(), isNull);
      });
    }
  });
}
