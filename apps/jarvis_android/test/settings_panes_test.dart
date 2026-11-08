import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/settings_page.dart';

import 'support.dart';

void main() {
  late JarvisController c;

  Future<void> open(WidgetTester t, Size size) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDisplayFeatures);
    c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(MaterialApp(home: SettingsPage(controller: c)));
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }

  final pane = find.byKey(const Key('settings-preview-pane'));

  testWidgets('Two panes from a usable width of 760 on a docked-list window', (
    t,
  ) async {
    await open(t, const Size(780, 610));
    expect(pane, findsOneWidget);
    expect(t.getSize(pane).width, closeTo(780 * .4, .5));
    // Narrower than 760: one column.
    t.view.physicalSize = const Size(740, 610);
    await t.pump();
    expect(pane, findsNothing);
    // Wide enough but the shortest side is under 600: one column.
    t.view.physicalSize = const Size(900, 590);
    await t.pump();
    expect(pane, findsNothing);
    // Taller than wide: one column.
    t.view.physicalSize = const Size(610, 800);
    await t.pump();
    expect(pane, findsNothing);
    await close(t);
  });

  testWidgets('Side margins are 14 with no 720 cap on the inner display', (
    t,
  ) async {
    await open(t, const Size(800, 1100));
    final cards = t.getRect(find.byKey(const Key('settings-cards')));
    expect(cards.left, 14);
    expect(cards.width, 800 - 28);
    // Two panes: the controls fill what is left of the window.
    t.view.physicalSize = const Size(1200, 700);
    await t.pump();
    final controls = t.getRect(find.byKey(const Key('settings-cards')));
    expect(controls.right, 1200 - 14);
    expect(controls.left, closeTo(1200 * .4 + 14, .5));
    await close(t);
  });

  testWidgets('Half-folded sideways: preview on the left screen, controls on '
      'the right, nothing on the crease', (t) async {
    await open(t, const Size(860, 608));
    t.view.displayFeatures = [
      const ui.DisplayFeature(
        bounds: ui.Rect.fromLTWH(425, 0, 10, 608),
        type: ui.DisplayFeatureType.fold,
        state: ui.DisplayFeatureState.postureHalfOpened,
      ),
    ];
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('settings-fold-split')), findsOneWidget);
    final preview = t.getRect(find.byKey(const Key('settings-preview')));
    expect(preview.right, lessThanOrEqualTo(425));
    expect(find.byTooltip('收起实时预览'), findsNothing);
    final cards = t.getRect(find.byKey(const Key('settings-cards')));
    expect(cards.left, 435 + 14);
    expect(cards.right, 860 - 14);
    expect(
      t.getRect(find.byKey(const Key('settings-chips-bar'))).left,
      greaterThanOrEqualTo(435),
    );
    expect(t.takeException(), isNull);
    // Opened flat: the ordinary two panes again.
    t.view.displayFeatures = [
      const ui.DisplayFeature(
        bounds: ui.Rect.fromLTWH(425, 0, 10, 608),
        type: ui.DisplayFeatureType.fold,
        state: ui.DisplayFeatureState.postureFlat,
      ),
    ];
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('settings-fold-split')), findsNothing);
    expect(pane, findsOneWidget);
    await close(t);
  });

  testWidgets('Half-folded with the crease across the window keeps one '
      'arrangement', (t) async {
    await open(t, const Size(860, 608));
    t.view.displayFeatures = [
      const ui.DisplayFeature(
        bounds: ui.Rect.fromLTWH(0, 299, 860, 10),
        type: ui.DisplayFeatureType.fold,
        state: ui.DisplayFeatureState.postureHalfOpened,
      ),
    ];
    await t.pump();
    expect(find.byKey(const Key('settings-fold-split')), findsNothing);
    expect(pane, findsOneWidget);
    await close(t);
  });
}
