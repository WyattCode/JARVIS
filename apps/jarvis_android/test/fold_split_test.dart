import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/voice_page.dart';

import 'foldable_test.dart' show host;
import 'support.dart';
import 'voice_layout_test.dart' show LayoutApi, settleTask;
import 'voice_support.dart';

ui.DisplayFeature crease(
  ui.Rect bounds, {
  ui.DisplayFeatureState state = ui.DisplayFeatureState.postureHalfOpened,
}) => ui.DisplayFeature(
  bounds: bounds,
  type: ui.DisplayFeatureType.fold,
  state: state,
);

Future<JarvisController> signedIn() async {
  final c = JarvisController(FakeApi(), MemoryVault());
  await c.initialize();
  await c.login('Wyatt', 'test');
  return c;
}

void main() {
  void useWindow(WidgetTester t, Size size) {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDisplayFeatures);
  }

  testWidgets('Half-folded sideways: list on the left screen, chat on the '
      'right, nothing on the crease', (t) async {
    useWindow(t, const Size(860, 608));
    final c = await signedIn();
    await t.pumpWidget(host(c));
    await t.pump();
    // Flat: the ordinary docked arrangement with its grip and menu button.
    expect(find.byKey(const Key('pane-grip')), findsOneWidget);
    expect(find.byTooltip(RegExp(r'^(收起|展开)会话$')), findsOneWidget);
    final flatWidth = t.getSize(find.byKey(const Key('docked-sidebar'))).width;

    t.view.displayFeatures = [crease(const ui.Rect.fromLTWH(425, 0, 10, 608))];
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);

    // The list reaches the crease's far edge.
    expect(t.getSize(find.byKey(const Key('docked-sidebar'))).width, 435);
    // Its rows stay clear of the crease; the chat starts after it.
    expect(
      t.getRect(find.byKey(const Key('new-conversation'))).right,
      lessThanOrEqualTo(425),
    );
    expect(
      t.getRect(find.byKey(const Key('chat-input'))).left,
      greaterThanOrEqualTo(435),
    );
    expect(t.getRect(find.byType(Composer)).left, greaterThanOrEqualTo(435));
    // It cannot be folded away: no grip, no menu button.
    expect(find.byKey(const Key('pane-grip')), findsNothing);
    expect(find.byTooltip(RegExp(r'^(收起|展开)会话$')), findsNothing);

    // The hinge opens again: the arrangement it had comes back.
    t.view.displayFeatures = [
      crease(
        const ui.Rect.fromLTWH(425, 0, 10, 608),
        state: ui.DisplayFeatureState.postureFlat,
      ),
    ];
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(t.getSize(find.byKey(const Key('docked-sidebar'))).width, flatWidth);
    expect(find.byKey(const Key('pane-grip')), findsOneWidget);
    expect(find.byTooltip(RegExp(r'^(收起|展开)会话$')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('A list the person folded away still has its screen half-folded, '
      'and is folded again when the hinge opens', (t) async {
    useWindow(t, const Size(860, 608));
    final c = await signedIn();
    await t.pumpWidget(host(c));
    await t.pump();
    await t.tap(find.byTooltip(RegExp(r'^(收起|展开)会话$')));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.getSize(find.byKey(const Key('docked-sidebar'))).width, 0);

    t.view.displayFeatures = [crease(const ui.Rect.fromLTWH(425, 0, 10, 608))];
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(t.getSize(find.byKey(const Key('docked-sidebar'))).width, 435);

    t.view.displayFeatures = [];
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(t.getSize(find.byKey(const Key('docked-sidebar'))).width, 0);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('A straight phone or an upright crease is not split', (t) async {
    useWindow(t, const Size(700, 360));
    final c = await signedIn();
    await t.pumpWidget(host(c));
    t.view.displayFeatures = [crease(const ui.Rect.fromLTWH(345, 0, 10, 360))];
    await t.pump();
    expect(find.byKey(const Key('docked-sidebar')), findsNothing);
    expect(t.takeException(), isNull);

    // Inner display held upright with the crease across it (screens one above
    // the other): the ordinary upright arrangement.
    t.view.physicalSize = const Size(608, 860);
    t.view.displayFeatures = [crease(const ui.Rect.fromLTWH(0, 425, 608, 10))];
    await t.pump();
    expect(find.byKey(const Key('docked-sidebar')), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Bending the hinge moves the halves over time, not at once', (
    t,
  ) async {
    useWindow(t, const Size(860, 608));
    final c = await signedIn();
    // Animations on (the shared host turns them off).
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh')],
        locale: const Locale('zh'),
        home: JarvisHome(controller: c),
      ),
    );
    await t.pump();
    double list() => t.getSize(find.byKey(const Key('docked-sidebar'))).width;
    double chat() => t.getRect(find.byKey(const Key('chat-input'))).left;
    final flatList = list(), flatChat = chat();

    Future<List<double>> sample(
      double Function() what, {
      int frames = 9,
    }) async {
      final out = <double>[];
      for (var i = 0; i < frames; i++) {
        await t.pump(const Duration(milliseconds: 50));
        out.add(what());
      }
      return out;
    }

    t.view.displayFeatures = [crease(const ui.Rect.fromLTWH(425, 0, 10, 608))];
    await t.pump();
    // The frame the hinge bends in: nothing has moved yet.
    expect(list(), closeTo(flatList, 1));
    expect(chat(), closeTo(flatChat, 1));
    final listIn = await sample(list, frames: 4);
    final chatIn = chat();
    // On its way: between where it was and where it is going, and growing.
    expect(listIn.first, greaterThan(flatList));
    expect(listIn.last, lessThan(435));
    for (var i = 1; i < listIn.length; i++) {
      expect(listIn[i], greaterThanOrEqualTo(listIn[i - 1]));
    }
    expect(chatIn, greaterThan(flatChat));
    expect(chatIn, lessThan(435 + 100));
    await t.pump(const Duration(milliseconds: 800));
    expect(list(), 435);

    // And back: the list gives its screen up gradually too.
    t.view.displayFeatures = [];
    await t.pump();
    expect(list(), closeTo(435, 1));
    final listOut = await sample(list, frames: 4);
    expect(listOut.first, lessThan(435));
    expect(listOut.last, greaterThan(flatList));
    for (var i = 1; i < listOut.length; i++) {
      expect(listOut[i], lessThanOrEqualTo(listOut[i - 1]));
    }
    await t.pump(const Duration(milliseconds: 800));
    expect(list(), closeTo(flatList, .5));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('A hinge that turns back in the middle does not jump', (t) async {
    useWindow(t, const Size(860, 608));
    final c = await signedIn();
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh')],
        locale: const Locale('zh'),
        home: JarvisHome(controller: c),
      ),
    );
    await t.pump();
    double list() => t.getSize(find.byKey(const Key('docked-sidebar'))).width;
    t.view.displayFeatures = [crease(const ui.Rect.fromLTWH(425, 0, 10, 608))];
    await t.pump();
    await t.pump(const Duration(milliseconds: 150));
    final mid = list();
    t.view.displayFeatures = [];
    await t.pump();
    expect(list(), closeTo(mid, 1));
    await t.pump(const Duration(milliseconds: 800));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Half-folded: the call page stands on the right screen only', (
    t,
  ) async {
    useWindow(t, const Size(860, 608));
    final c = JarvisController(
      LayoutApi(),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await c.initialize();
    await c.login('Wyatt', 'test');
    t.view.displayFeatures = [crease(const ui.Rect.fromLTWH(425, 0, 10, 608))];
    await t.pumpWidget(host(c));
    await t.pump();
    await settleTask(t, c.voice.start(c.current));
    await t.pump();
    final page = t.getRect(find.byType(VoiceOverlay));
    expect(page.left, greaterThanOrEqualTo(435));
    expect(page.right, 860);
    expect(t.takeException(), isNull);

    // Flat again: the call page covers the whole window.
    t.view.displayFeatures = [];
    await t.pump();
    expect(t.getRect(find.byType(VoiceOverlay)).left, 0);
    await t.pumpWidget(const SizedBox());
    await settleTask(t, c.voice.stop());
    c.dispose();
  });

  testWidgets('Outer display: the drawer still closes by a tap beside it', (
    t,
  ) async {
    useWindow(t, const Size(425, 623));
    final c = await signedIn();
    await t.pumpWidget(host(c));
    await t.pump();
    await t.tap(find.byTooltip('展开会话'));
    await t.pumpAndSettle();
    final drawer = t.getRect(find.byType(Drawer));
    expect(drawer.width, lessThan(425));
    await t.tapAt(Offset(drawer.right + 20, 300));
    await t.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Inner display upright: the list is a page of its own', (
    t,
  ) async {
    useWindow(t, const Size(608, 860));
    final c = await signedIn();
    await t.pumpWidget(host(c));
    await t.pump();
    await t.tap(find.byTooltip('展开会话'));
    await t.pumpAndSettle();
    final drawer = t.getRect(find.byType(Drawer));
    expect(drawer.width, 608);
    expect(drawer.left, 0);
    expect(find.byKey(const Key('close-conversation-page')), findsOneWidget);

    await t.tap(find.byKey(const Key('close-conversation-page')));
    await t.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);

    // The outer display keeps its drawer.
    t.view.physicalSize = const Size(425, 623);
    await t.pump();
    await t.tap(find.byTooltip('展开会话'));
    await t.pumpAndSettle();
    expect(t.getRect(find.byType(Drawer)).width, lessThan(425));
    expect(find.byKey(const Key('close-conversation-page')), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
