import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';

import 'c2_support.dart';
import 'support.dart';

Future<JarvisController> pumpSettings(
  WidgetTester t, {
  required Size size,
  EdgeInsets insets = EdgeInsets.zero,
  DuoLayout layout = DuoLayout.none,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  sizeWindow(t, size, insets);
  final c = JarvisController(SpeechApi(), MemoryVault());
  await c.initialize();
  await c.login('user', 'test');
  await t.pumpWidget(
    DuoLayoutScope(
      layout: ValueNotifier(layout),
      child: appHost(
        SettingsPage(controller: c),
        scale: scale,
        brightness: brightness,
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 400));
  return c;
}

/// Ends a test that changed settings: a pending save timer needs the tree gone first.
Future<void> close(WidgetTester t, JarvisController c) async {
  await t.pumpWidget(const SizedBox());
  c.dispose();
}

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

void main() {
  group('large text', () {
    for (final scale in [2.0, 2.4]) {
      testWidgets(
        'slider rows do not overflow at x$scale on the outer display',
        (t) async {
          final c = await pumpSettings(
            t,
            size: const Size(466, 678),
            insets: const EdgeInsets.only(right: 84, bottom: 34),
            layout: outerDisplay,
            scale: scale,
          );
          for (final key in ['message-font-size', 'threshold-slider']) {
            await t.ensureVisible(find.byKey(Key(key)));
            await t.pump();
            expect(t.takeException(), isNull, reason: key);
          }
          expect(find.text('聊天字号'), findsOneWidget);
          expect(find.text('麦克风灵敏度'), findsOneWidget);
          await close(t, c);
        },
      );
    }

    testWidgets('the value moves under the name at accessibility sizes', (
      t,
    ) async {
      await t.pumpWidget(
        appHost(
          const Scaffold(
            body: SliderHeader(title: '聊天字号', value: '16（默认）'),
          ),
          scale: 2,
        ),
      );
      expect(
        t.getTopLeft(find.text('16（默认）')).dy,
        greaterThan(t.getBottomLeft(find.text('聊天字号')).dy - 1),
      );
      await t.pumpWidget(
        appHost(
          const Scaffold(
            body: SliderHeader(title: '聊天字号', value: '16（默认）'),
          ),
        ),
      );
      expect(
        t.getTopLeft(find.text('16（默认）')).dy,
        closeTo(t.getTopLeft(find.text('聊天字号')).dy, 2),
      );
    });

    testWidgets('chips keep their text size and the capsule grows', (t) async {
      final c = await pumpSettings(
        t,
        size: const Size(375, 667),
        insets: const EdgeInsets.only(top: 20),
        scale: 2.4,
      );
      final bar = find.byKey(const Key('settings-chips-bar'));
      for (var i = 0; i < 4; i++) {
        final chip = find.byKey(ValueKey('settings-chip-$i'));
        expect(t.getSize(chip).height, greaterThan(44));
        final label = find.descendant(of: chip, matching: find.byType(Text));
        // getRect applies a FittedBox's scale; getSize does not: equal means the label is not shrunk.
        expect(
          t.getRect(label).size.height,
          closeTo(t.getSize(label).height, .01),
        );
      }
      // The first section starts below the taller bar.
      final title = find.descendant(
        of: find.byKey(const Key('settings-scroll')),
        matching: find.text('外观'),
      );
      expect(
        t.getRect(title).top,
        greaterThanOrEqualTo(t.getRect(find.byType(SettingsChips)).bottom),
      );
      expect(bar, findsOneWidget);
      await close(t, c);
    });
  });

  group('semantics', () {
    testWidgets('the font size slider reads the size and steps by one size', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      final c = await pumpSettings(t, size: const Size(466, 900));
      await t.ensureVisible(find.byKey(const Key('message-font-size')));
      await t.pump();
      final node = find.semantics.byValue('16');
      expect(node, findsOneWidget);
      final data = node.evaluate().single.getSemanticsData();
      expect(data.label, '聊天字号');
      expect(data.increasedValue, '18');
      expect(data.decreasedValue, '14');
      t.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          type: ui.SemanticsAction.increase,
          viewId: t.view.viewId,
          nodeId: node.evaluate().single.id,
        ),
      );
      await t.pump();
      expect(c.settings.messageFontSize, 18);
      semantics.dispose();
      await close(t, c);
    });

    testWidgets('a picker row is one button with its value and a menu hint', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      final c = await pumpSettings(t, size: const Size(466, 900));
      final node = find.semantics.byLabel('思考深度');
      expect(node, findsOneWidget);
      final data = node.evaluate().single.getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.value, '高（默认）');
      expect(data.hint, '打开菜单');
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      t.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          type: ui.SemanticsAction.tap,
          viewId: t.view.viewId,
          nodeId: node.evaluate().single.id,
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('低'), findsOneWidget, reason: 'the menu opened');
      semantics.dispose();
      await close(t, c);
    });
  });

  testWidgets('a picker menu opens under the value, at the right of the row', (
    t,
  ) async {
    final c = await pumpSettings(t, size: const Size(466, 900));
    final row = t.getRect(
      find.ancestor(
        of: find.text('思考深度'),
        matching: find.byType(PickerRow<String>),
      ),
    );
    await t.tap(find.text('思考深度'));
    await t.pumpAndSettle();
    final item = t.getRect(find.widgetWithText(PopupMenuItem<String>, '低'));
    // The item sits 6 pt inside the menu surface (the same padding as the call page's action menu).
    expect(item.right + 6, closeTo(row.right - 8, 1));
    expect(item.left, greaterThan(row.left + row.width / 2 - 60));
    expect(t.takeException(), isNull);
    await t.tap(find.text('低'));
    await t.pumpAndSettle();
    await close(t, c);
  });

  group('theme swatches', () {
    for (final brightness in Brightness.values) {
      testWidgets(
        'selection shows a check and the idle outline has 3:1 (${brightness.name})',
        (t) async {
          String value = 'light';
          await t.pumpWidget(
            appHost(
              Scaffold(
                body: StatefulBuilder(
                  builder: (context, set) => SettingsGroup(
                    children: [
                      ThemeSwatches(
                        value: value,
                        onChanged: (v) => set(() => value = v),
                      ),
                    ],
                  ),
                ),
              ),
              brightness: brightness,
            ),
          );
          await t.pump(const Duration(milliseconds: 50));
          // The tile's own press scale comes first; the check mark's scale is the last one inside it.
          double scaleOf(String id) => t
              .widget<AnimatedScale>(
                find
                    .descendant(
                      of: find.byKey(ValueKey('theme-$id')),
                      matching: find.byType(AnimatedScale),
                    )
                    .last,
              )
              .scale;
          expect(scaleOf('light'), 1);
          expect(scaleOf('dark'), 0);
          expect(scaleOf('system'), 0);
          final colors = themeFor(brightness).colorScheme;
          final fill = SettingsGroup.fill(colors);
          BoxDecoration decoration(String id) =>
              t
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: find.byKey(ValueKey('theme-$id')),
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration!
                  as BoxDecoration;
          final idle = (decoration('dark').border! as Border).top;
          final chosen = (decoration('light').border! as Border).top;
          expect(contrast(idle.color, fill), greaterThanOrEqualTo(3));
          expect(chosen.width, greaterThan(idle.width));
          await t.tap(find.byKey(const ValueKey('theme-dark')));
          await t.pump(const Duration(milliseconds: 400));
          expect(scaleOf('dark'), 1);
          expect(scaleOf('light'), 0);
        },
      );
    }
  });

  group('voice rows', () {
    Widget row({bool selected = false, bool loading = false}) => appHost(
      Scaffold(
        body: SettingsGroup(
          children: [
            VoiceChoiceRow(
              name: '星衡',
              description: '沉稳',
              selected: selected,
              playing: false,
              loading: loading,
              onSelect: () {},
              onPlay: () {},
            ),
          ],
        ),
      ),
    );

    testWidgets('the chosen voice has a check mark, not a radio', (t) async {
      await t.pumpWidget(row(selected: true));
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_checked), findsNothing);
      await t.pumpWidget(row());
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(find.byIcon(Icons.radio_button_off), findsNothing);
      expect(t.getSize(find.byType(ListTile)).height, greaterThanOrEqualTo(44));
      expect(
        t.getSize(find.byType(IconButton)).height,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('loading swaps the play icon for a 14 pt spinner', (t) async {
      await t.pumpWidget(row());
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await t.pumpWidget(row(loading: true));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(
        t.getSize(find.byType(CircularProgressIndicator)),
        const Size.square(14),
      );
      expect(find.byTooltip('正在加载试听'), findsOneWidget);
      expect(
        t.getSize(find.byType(IconButton)).height,
        greaterThanOrEqualTo(44),
      );
    });
  });

  group('every tab on every device', () {
    final poses = [...straightPoses, ...foldPoses];
    for (final pose in poses) {
      for (final scale in textScales) {
        for (final brightness in Brightness.values) {
          testWidgets('settings ${pose.name} x$scale ${brightness.name}', (
            t,
          ) async {
            final layout = switch (pose.name) {
              'outer' => outerDisplay,
              'inner landscape' => flatLandscape,
              _ => DuoLayout.none,
            };
            final c = await pumpSettings(
              t,
              size: pose.size,
              insets: pose.insets,
              layout: layout,
              scale: scale,
              brightness: brightness,
            );
            final safe = pose.safe;
            // Every chip is a 44 pt target inside the safe area, one per tab.
            for (var i = 0; i < 4; i++) {
              final r = t.getRect(find.byKey(ValueKey('settings-chip-$i')));
              expect(r.height, greaterThanOrEqualTo(44));
              expect(r.left, greaterThanOrEqualTo(safe.left - .5));
              expect(r.right, lessThanOrEqualTo(safe.right + .5));
            }
            // Walk the whole page: nothing overflows and no row reaches under the side insets.
            final scroll = find.byKey(const Key('settings-scroll'));
            for (var step = 0; step < 40; step++) {
              expect(t.takeException(), isNull, reason: 'step $step');
              for (final tile in find.byType(SettingsGroup).evaluate()) {
                final r = t.getRect(find.byWidget(tile.widget));
                expect(r.left, greaterThanOrEqualTo(safe.left - .5));
                expect(r.right, lessThanOrEqualTo(safe.right + .5));
              }
              await t.drag(scroll, Offset(0, -pose.size.height / 2));
              await t.pump(const Duration(milliseconds: 50));
            }
            await close(t, c);
          });
        }
      }
    }
  });
}
