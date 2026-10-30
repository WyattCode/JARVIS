import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

/// A pose: the window, and the padding the system keeps clear (status bar, home indicator, the Duo's right strip).
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

void _setUpView(WidgetTester t, _Pose pose, double scale) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = pose.size;
  t.view.padding = pose.padding;
  t.view.viewPadding = pose.padding;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPadding);
  addTearDown(t.view.resetViewPadding);
  addTearDown(t.view.resetViewInsets);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  for (final pose in _poses) {
    for (final scale in [1.0, 1.3, 2.0, 2.4]) {
      testWidgets(
        'login keeps its fields and button on screen at ${pose.size} x$scale',
        (t) async {
          _setUpView(t, pose, scale);
          final c = JarvisController(FakeApi(), MemoryVault());
          await t.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
          await t.pump(const Duration(milliseconds: 400));
          final visible = Rect.fromLTRB(
            pose.padding.left,
            pose.padding.top,
            pose.size.width - pose.padding.right,
            pose.size.height - pose.padding.bottom,
          );
          final button = t.getRect(find.widgetWithText(FilledButton, '登录'));
          expect(button.bottom, lessThanOrEqualTo(visible.bottom + .01));
          for (final field in find.byType(TextField).evaluate()) {
            final rect = t.getRect(find.byWidget(field.widget));
            expect(rect.top, greaterThanOrEqualTo(visible.top));
            expect(rect.bottom, lessThanOrEqualTo(button.top));
            expect(rect.left, greaterThanOrEqualTo(visible.left));
            expect(rect.right, lessThanOrEqualTo(visible.right + .01));
          }
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
          c.dispose();
        },
      );
    }
  }

  // iOS steps viewInsets itself every frame; the button must never sit under the keyboard at any of those frames.
  for (final entry in {
    const Size(436, 948): [400.0, 1.0],
    const Size(430, 932): [336.0, 1.0],
    const Size(400, 800): [336.0, 1.3],
  }.entries) {
    testWidgets(
      'login button never dips under a rising keyboard ${entry.key}',
      (t) async {
        final pose = _Pose(entry.key, const FakeViewPadding(bottom: 34));
        _setUpView(t, pose, entry.value[1]);
        final c = JarvisController(FakeApi(), MemoryVault());
        // iOS hands the stepped inset over as it is (no glide on top of it).
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: LoginPage(controller: c),
          ),
        );
        await t.pump(const Duration(milliseconds: 400));
        final button = find.widgetWithText(FilledButton, '登录');
        final keyboard = entry.value[0];
        for (var ms = 0; ms <= 480; ms += 16) {
          final inset = keyboard * Curves.easeOutCubic.transform(ms / 480);
          t.view.viewInsets = FakeViewPadding(bottom: inset);
          await t.pump(const Duration(milliseconds: 16));
          expect(
            t.getRect(button).bottom,
            lessThanOrEqualTo(entry.key.height - inset + .01),
            reason: 'button under the keyboard at ${ms}ms',
          );
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }

  // A server's explanation is shown whole under the title: the hero gives way to it, so the button stays on screen.
  const error = '账户或密码不正确，请检查后重试。如果多次失败，账户会被暂时锁定十五分钟，请联系管理员处理。';
  for (final pose in _poses) {
    for (final scale in [1.0, 1.3, 2.0, 2.4]) {
      testWidgets(
        'login with a server error keeps its button on screen at ${pose.size} x$scale',
        (t) async {
          _setUpView(t, pose, scale);
          final c = JarvisController(FakeApi(), MemoryVault())..error = error;
          await t.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
          await t.pump(const Duration(milliseconds: 400));
          expect(find.text(error), findsOneWidget);
          final button = t.getRect(find.widgetWithText(FilledButton, '登录'));
          expect(
            button.bottom,
            lessThanOrEqualTo(pose.size.height - pose.padding.bottom + .01),
          );
          expect(
            t.getRect(find.text(error)).top,
            greaterThanOrEqualTo(pose.padding.top),
          );
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
          c.dispose();
        },
      );
    }
  }

  // With the keyboard up a short window lets the hero go; where even that is not enough, the focused field brings the
  // button up with it. Either way the field and the button end up whole above the keyboard.
  for (final entry in {
    _Pose(Size(375, 667), FakeViewPadding(top: 20)): 260.0,
    _Pose(Size(466, 678), FakeViewPadding(right: 84, bottom: 34)): 336.0,
    _Pose(Size(402, 874), FakeViewPadding(top: 62, bottom: 34)): 336.0,
  }.entries) {
    final pose = entry.key, keyboard = entry.value;
    for (final scale in [1.0, 1.3, 2.0]) {
      for (final field in [0, 1]) {
        testWidgets(
          'login button comes up above the keyboard at ${pose.size} x$scale '
          '(${field == 0 ? 'account' : 'password'} field)',
          (t) async {
            _setUpView(t, pose, scale);
            final c = JarvisController(FakeApi(), MemoryVault());
            await t.pumpWidget(
              MaterialApp(
                theme: ThemeData(platform: TargetPlatform.iOS),
                home: LoginPage(controller: c),
              ),
            );
            await t.pump(const Duration(milliseconds: 400));
            final fields = find.byType(TextField);
            await t.tap(fields.at(field));
            await t.pump();
            for (var ms = 0; ms <= 480; ms += 16) {
              final inset = keyboard * Curves.easeOutCubic.transform(ms / 480);
              t.view.viewInsets = FakeViewPadding(bottom: inset);
              await t.pump(const Duration(milliseconds: 16));
            }
            await t.pump(const Duration(milliseconds: 400));
            final top = t.getRect(fields.at(field)).top;
            final button = t.getRect(find.widgetWithText(FilledButton, '登录'));
            expect(top, greaterThanOrEqualTo(pose.padding.top - .01));
            expect(
              button.bottom,
              lessThanOrEqualTo(pose.size.height - keyboard + .01),
            );
            expect(t.takeException(), isNull);
            await t.pumpWidget(const SizedBox());
            c.dispose();
          },
        );
      }
    }
  }

  // The rise alone, nothing focused yet: on the short phones the hero goes, so a keyboard without the suggestions bar
  // (260 pt on a Touch ID phone, 291 pt with the home indicator) leaves the button in sight on its own.
  for (final pose in const [
    _Pose(Size(375, 667), FakeViewPadding(top: 20)),
    _Pose(Size(466, 678), FakeViewPadding(right: 84, bottom: 34)),
  ]) {
    testWidgets('login hero gives way to a keyboard at ${pose.size}', (
      t,
    ) async {
      _setUpView(t, pose, 1.0);
      final c = JarvisController(FakeApi(), MemoryVault());
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: LoginPage(controller: c),
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      final keyboard = pose.size.height < 670 ? 260.0 : 291.0;
      final button = find.widgetWithText(FilledButton, '登录');
      for (var ms = 0; ms <= 480; ms += 16) {
        final inset = keyboard * Curves.easeOutCubic.transform(ms / 480);
        t.view.viewInsets = FakeViewPadding(bottom: inset);
        await t.pump(const Duration(milliseconds: 16));
        expect(
          t.getRect(button).bottom,
          lessThanOrEqualTo(pose.size.height - inset + .01),
          reason: 'button under the keyboard at ${ms}ms',
        );
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}
