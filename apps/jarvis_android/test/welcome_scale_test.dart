import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

class _Pose {
  const _Pose(this.size, this.padding);
  final Size size;
  final FakeViewPadding padding;
}

const _poses = [
  _Pose(Size(375, 667), FakeViewPadding(top: 20)),
  _Pose(Size(400, 800), FakeViewPadding(top: 47, bottom: 34)),
  _Pose(Size(430, 932), FakeViewPadding(top: 59, bottom: 34)),
  _Pose(Size(466, 678), FakeViewPadding(right: 84, bottom: 34)),
  _Pose(Size(678, 466), FakeViewPadding(right: 84, bottom: 34)),
  _Pose(Size(844, 390), FakeViewPadding(left: 47, right: 47, bottom: 21)),
];

void main() {
  for (final pose in _poses) {
    for (final offline in [false, true]) {
      for (final scale in [1.0, 1.3, 2.0, 2.4]) {
        testWidgets(
          'welcome never cuts a part mid-glyph at ${pose.size} x$scale'
          '${offline ? ' offline' : ''}',
          (t) async {
            t.view.devicePixelRatio = 1;
            t.view.physicalSize = pose.size;
            t.view.padding = pose.padding;
            t.view.viewPadding = pose.padding;
            t.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(t.view.resetPhysicalSize);
            addTearDown(t.view.resetDevicePixelRatio);
            addTearDown(t.view.resetPadding);
            addTearDown(t.view.resetViewPadding);
            addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
            final c = JarvisController(FakeApi(), MemoryVault());
            await c.initialize();
            addTearDown(c.dispose);
            await t.pumpWidget(
              DuoLayoutScope(
                layout: ValueNotifier(DuoLayout.none),
                child: MaterialApp(
                  home: JarvisHome(
                    controller: c,
                    offline: () => offline,
                    onRetry: () {},
                  ),
                ),
              ),
            );
            await t.pump(const Duration(milliseconds: 600));
            final title = find.text('想聊点什么？');
            expect(title, findsOneWidget);
            final scrollable = find
                .ancestor(of: title, matching: find.byType(Scrollable))
                .first;
            final page = t.getRect(scrollable);
            // The four cards always stay: when even without the avatar and the hint they are taller than the page, the
            // page scrolls (only then may a card run past its bottom edge, by no more than the page scrolls).
            final scrolls = t
                .state<ScrollableState>(scrollable)
                .position
                .maxScrollExtent;
            // A part that is not shown has no height or no opacity; one that is shown lies whole inside the page.
            bool shown(Finder f) =>
                f.evaluate().isNotEmpty &&
                !find
                    .ancestor(of: f, matching: find.byType(Opacity))
                    .evaluate()
                    .any((e) => (e.widget as Opacity).opacity < .5);
            final parts = <String, Finder>{
              'title': title,
              'hint': find.text('写下想法，或直接开口。'),
              'avatar': find.byType(CoreAvatar),
              for (var i = 0; i < 4; i++)
                'card $i': find.byKey(ValueKey('starter-$i')),
            };
            for (final MapEntry(:key, :value) in parts.entries) {
              if (!shown(value)) continue;
              final rect = t.getRect(value.first);
              expect(
                rect.bottom,
                lessThanOrEqualTo(
                  page.bottom + (key.startsWith('card') ? scrolls : 0) + .5,
                ),
                reason: '$key is cut at the bottom of the page $page: $rect',
              );
              expect(rect.height, lessThanOrEqualTo(page.height + .5));
              expect(
                rect.top,
                greaterThanOrEqualTo(page.top - .5),
                reason: '$key is cut at the top of the page $page: $rect',
              );
            }
            for (var i = 0; i < 4; i++) {
              expect(shown(parts['card $i']!), isTrue, reason: 'card $i');
            }
            expect(t.takeException(), isNull);
            await t.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
