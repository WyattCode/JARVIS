import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';

import 'duo_rail_test.dart' show pumpHome;

void main() {
  testWidgets(
    'settings builds over the first frames of its push, while it is still off screen',
    (t) async {
      await pumpHome(
        t,
        DuoLayout.none,
        size: const Size(402, 874),
        platform: TargetPlatform.iOS,
      );
      await t.pump(const Duration(seconds: 1));
      (t.state(find.byType(JarvisHome)) as dynamic).settings();
      final finder = find.byType(SettingsSection, skipOffstage: false);
      int rows() => finder
          .evaluate()
          .map((e) => (e.widget as SettingsSection).children.length)
          .fold(0, (a, b) => a + b);
      final counts = <int>[];
      double? builtBottom;
      for (var frame = 0; frame < 30; frame++) {
        await t.pump(const Duration(milliseconds: 8));
        final page = t.getRect(
          find.byKey(const Key('settings-scroll'), skipOffstage: false),
        );
        final now = rows();
        if (frame >= 1 && frame <= 2) {
          // The first frame lays the page out offstage (not painted); the next two, which bring in the first
          // screenful, come while the page is still all but off screen.
          expect(page.left, greaterThan(402 * .9), reason: 'frame $frame');
        }
        if (frame >= 3 && now > counts.last) {
          // Later rows come below the first screenful, or while the page is still all but off screen.
          expect(
            builtBottom! >= 874 || page.left > 402 * .85,
            isTrue,
            reason:
                'frame $frame: rows from $builtBottom, page at ${page.left}',
          );
        }
        if (frame > 0) {
          expect(
            now - counts.last,
            lessThanOrEqualTo(SettingsPage.rowsPerFrame),
            reason: 'a few rows a frame: $counts',
          );
        }
        counts.add(now);
        builtBottom = t.getRect(finder.last).bottom;
      }
      expect(counts.first, SettingsPage.rowsPerFrame);
      final all = counts.last;
      await t.pump(const Duration(milliseconds: 600));
      expect(rows(), all, reason: 'all built within the frames above');
    },
  );

  testWidgets('whatever is left is built once the slide ends', (t) async {
    await pumpHome(
      t,
      DuoLayout.none,
      size: const Size(402, 874),
      platform: TargetPlatform.iOS,
    );
    await t.pump(const Duration(seconds: 1));
    (t.state(find.byType(JarvisHome)) as dynamic).settings();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.text('退出登录', skipOffstage: false), findsOneWidget);
  });

  testWidgets('the chips bar blurs only once rows scroll under it', (t) async {
    await pumpHome(t, DuoLayout.none, size: const Size(402, 874));
    await t.pump(const Duration(seconds: 1));
    (t.state(find.byType(JarvisHome)) as dynamic).settings();
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    bool blurring() =>
        t.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled;
    expect(blurring(), isFalse);
    await t.drag(
      find.byKey(const Key('settings-scroll')),
      const Offset(0, -200),
    );
    await t.pump();
    expect(blurring(), isTrue);
    await t.drag(
      find.byKey(const Key('settings-scroll')),
      const Offset(0, 400),
    );
    await t.pump(const Duration(seconds: 1));
    expect(blurring(), isFalse);
  });
}
