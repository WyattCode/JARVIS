import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/completed_works.dart';
import 'package:jarvis_android/ui/design_tokens.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/media_widgets.dart';
import 'package:jarvis_android/ui/privacy_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';
import 'package:jarvis_android/ui/sidebar_split.dart';

import 'c2_support.dart';
import 'support.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + .05 : lb + .05) / (la > lb ? lb + .05 : la + .05);
}

void main() {
  group('attachment picture viewer', () {
    Future<void> openPicture(
      WidgetTester t,
      DuoLayout layout,
      Size size,
    ) async {
      sizeWindow(
        t,
        size,
        layout.hasVerticalBar
            ? const EdgeInsets.only(right: 84, bottom: 34)
            : const EdgeInsets.only(top: 62, bottom: 34),
      );
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await c.blobs.put('img', Uint8List.fromList(png));
      final image = Attachment(
        id: 'img',
        name: 'cat.png',
        mime: 'image/png',
        kind: 'image',
      );
      await t.pumpWidget(
        withLayout(
          layout,
          appHost(
            Scaffold(
              body: AttachmentCard(controller: c, item: image, preview: true),
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      await t.tap(find.byKey(const Key('attachment-thumb-img')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
    }

    testWidgets('outer display: back stands in the right strip, not the bar', (
      t,
    ) async {
      await openPicture(t, outerDisplay, const Size(466, 678));
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      final back = find.byKey(const Key('duo-rail-back'));
      expect(back, findsOneWidget);
      final strip = t.getRect(find.byKey(const Key('duo-rail')));
      expect(strip.left, greaterThanOrEqualTo(466 - 84));
      expect(strip.contains(t.getCenter(back)), isTrue);
      await t.tap(back);
      await t.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('a normal phone keeps the AppBar back button', (t) async {
      await openPicture(t, DuoLayout.none, const Size(402, 874));
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byKey(const Key('duo-rail')), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('cat.png'), findsOneWidget);
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    });
  });

  group('AI disclosure link', () {
    for (final brightness in Brightness.values) {
      testWidgets(
        'is an accent coloured, underlined link (${brightness.name})',
        (t) async {
          sizeWindow(t, const Size(402, 874), const EdgeInsets.only(top: 62));
          final c = JarvisController(FakeApi(), MemoryVault());
          await c.initialize();
          addTearDown(c.dispose);
          await t.pumpWidget(
            appHost(
              Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showAiDisclosure(context, controller: c),
                    child: const Text('开'),
                  ),
                ),
              ),
              brightness: brightness,
            ),
          );
          await t.tap(find.text('开'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
          final link = find.byKey(const Key('disclosure-privacy'));
          expect(link, findsOneWidget);
          expect(t.getSize(link).height, greaterThanOrEqualTo(44));
          final text = t.widget<Text>(
            find.descendant(of: link, matching: find.text('查看隐私与数据使用')),
          );
          expect(text.style?.decoration, TextDecoration.underline);
          expect(
            find.descendant(
              of: link,
              matching: find.byIcon(Icons.chevron_right),
            ),
            findsOneWidget,
          );
          // The dialog's surface in the app's theme (main.dart): surfaceContainerHigh.
          final surface = brightness == Brightness.dark
              ? const Color(0xff1c1c20)
              : const Color(0xffedf0ef);
          final shown = DefaultTextStyle.of(
            t.element(
              find.descendant(of: link, matching: find.text('查看隐私与数据使用')),
            ),
          ).style.color!;
          expect(shown, JarvisColors.accent(t.element(link)));
          final body = contrast(shown, surface);
          expect(body, greaterThanOrEqualTo(4.5));
          expect(
            find.bySemanticsLabel('查看隐私与数据使用'),
            findsOneWidget,
            reason: 'still one button for VoiceOver',
          );
        },
      );
    }

    test('the accent keeps 4.5:1 on the light cards and dialogs', () {
      for (final surface in const [
        Color(0xffffffff), // card
        Color(0xfff9faf9), // page
        Color(0xffedf0ef), // dialog
        Color(0xffe8edeb),
      ]) {
        expect(
          contrast(const Color(0xff137589), surface),
          greaterThanOrEqualTo(4.5),
          reason: '$surface',
        );
      }
    });
  });

  group('sidebar grip', () {
    testWidgets('is 44 pt wide to drag, 24 pt to tap, and does not shift', (
      t,
    ) async {
      var visible = true;
      final taps = <String>[];
      late StateSetter update;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) {
                update = set;
                return SidebarSplit(
                  width: 240,
                  visible: visible,
                  duration: Duration.zero,
                  onChanged: (v) => update(() => visible = v),
                  content: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps.add('content'),
                    child: const SizedBox.expand(),
                  ),
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        ),
      );
      final grip = find.byKey(const Key('pane-grip'));
      final reach = find.byKey(const Key('pane-grip-reach'));
      final g = t.getRect(grip), r = t.getRect(reach);
      expect(
        g.width,
        24,
        reason: 'the visible grip and its tap area are as before',
      );
      expect(g.left, 240);
      expect(r.left, g.right);
      expect(r.right - g.left, greaterThanOrEqualTo(44));
      expect(t.getRect(find.byKey(const Key('pane-grip-thumb'))).left, 250);
      // A tap beside the grip (past its 24 pt) still reaches the content under it.
      await t.tapAt(Offset(g.right + 10, g.center.dy));
      expect(taps, ['content']);
      expect(visible, isTrue);
      // A drag that starts in the extra 20 pt moves the pane.
      final drag = await t.startGesture(Offset(g.right + 10, g.center.dy));
      await drag.moveBy(const Offset(-30, 0));
      await drag.moveBy(const Offset(-200, 0));
      await drag.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(visible, isFalse);
      expect(t.getRect(grip).left, 0);
      expect(t.getRect(reach).right, 44);
    });
  });

  group('works sheet grabber', () {
    testWidgets('answers a 44 pt tall touch and closes the sheet', (t) async {
      sizeWindow(t, const Size(402, 874), const EdgeInsets.only(top: 62));
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      late BuildContext host;
      await t.pumpWidget(
        appHost(
          Builder(
            builder: (context) {
              host = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      unawaited(showGeneratedWorks(host, c));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final grabber = find.byKey(const Key('works-grabber'));
      expect(t.getSize(grabber).height, greaterThanOrEqualTo(44));
      expect(t.getSize(grabber).width, greaterThanOrEqualTo(44));
      final title = t.getRect(find.text('生成作品'));
      // The title row keeps its place: 24 pt grabber area above it as before.
      final sheetTop = t.getRect(grabber).top;
      expect(title.top - sheetTop, lessThan(44));
      expect(find.bySemanticsLabel('关闭生成作品'), findsOneWidget);
      // Touch 40 pt below the sheet's top edge: still the grabber.
      await t.tapAt(Offset(t.getCenter(grabber).dx, sheetTop + 40));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('生成作品'), findsNothing);
    });
  });

  group('settings field rows', () {
    testWidgets('hint is 4.5:1 or more and the row shows a pencil', (t) async {
      for (final brightness in Brightness.values) {
        final controller = TextEditingController();
        await t.pumpWidget(
          appHost(
            Scaffold(
              body: SettingsGroup(
                children: [
                  FieldRow(
                    label: '助手指令',
                    controller: controller,
                    hint: '为助手设定角色',
                    onChanged: (_) {},
                  ),
                ],
              ),
            ),
            brightness: brightness,
          ),
        );
        final colors = Theme.of(t.element(find.byType(FieldRow))).colorScheme;
        final field = t.widget<TextField>(find.byType(TextField));
        final hint = field.decoration!.hintStyle!.color!;
        final card = SettingsGroup.fill(colors);
        expect(
          contrast(Color.alphaBlend(hint, card), card),
          greaterThanOrEqualTo(4.5),
          reason: brightness.name,
        );
        final pencil = find.byKey(const Key('field-edit-助手指令'));
        expect(pencil, findsOneWidget);
        expect(t.widget<AnimatedOpacity>(pencil).opacity, 1);
        final before = t.getSize(find.byType(FieldRow));
        await t.tap(find.byType(TextField));
        await t.pump(const Duration(milliseconds: 300));
        expect(t.widget<AnimatedOpacity>(pencil).opacity, 0);
        expect(t.getSize(find.byType(FieldRow)), before, reason: 'no shift');
        await t.pumpWidget(const SizedBox());
        controller.dispose();
      }
    });
  });
}
