import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoSlider;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/action_menu.dart';
import 'package:jarvis_android/ui/completed_works.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/media_widgets.dart';
import 'package:jarvis_android/ui/privacy_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';
import 'package:jarvis_android/ui/sidebar_split.dart';
import 'package:jarvis_android/ui/status_page.dart';
import 'package:jarvis_android/ui/voice_mode_selector.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/ui/voice_picker.dart';

import 'c2_support.dart';
import 'support.dart';
import 'voice_support.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// The outer display turned on its side: the strip stays on the right.
final outerLandscape = DuoLayout.fromMap({
  'edge': 'right',
  'width': 678.0,
  'height': 466.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 21.0},
  'regions': [
    {
      'kind': 'occlusion',
      'active': true,
      'x': 594.0,
      'y': 0.0,
      'w': 84.0,
      'h': 120.0,
    },
  ],
});

const phone = Pose(
  'Pro portrait',
  Size(402, 874),
  EdgeInsets.only(top: 62, bottom: 34),
);
const phoneLandscape = Pose(
  'Pro landscape',
  Size(874, 402),
  EdgeInsets.only(left: 62, right: 62, bottom: 21),
);

Future<JarvisController> pumpVoice(
  WidgetTester t, {
  required Size size,
  EdgeInsets insets = EdgeInsets.zero,
  DuoLayout layout = DuoLayout.none,
}) async {
  sizeWindow(t, size, insets);
  final c = JarvisController(
    FakeApi(),
    MemoryVault(),
    audioDevice: FakeAudio(),
  );
  await c.initialize();
  addTearDown(c.dispose);
  c.settings.voiceMode = 'ptt';
  c.voice.owner = c.current;
  await t.pumpWidget(
    DuoLayoutScope(
      layout: ValueNotifier(layout),
      child: appHost(VoicePage(controller: c)),
    ),
  );
  await t.pump();
  return c;
}

void main() {
  group('1 attachment picture viewer keeps left of the strip', () {
    for (final (name, layout, size, insets) in [
      (
        'outer',
        outerDisplay,
        const Size(466, 678),
        const EdgeInsets.only(right: 84, bottom: 34),
      ),
      (
        'outer landscape',
        outerLandscape,
        const Size(678, 466),
        const EdgeInsets.only(right: 84, bottom: 21),
      ),
      (
        'inner landscape',
        flatLandscape,
        const Size(951, 669),
        const EdgeInsets.only(right: 84, bottom: 34),
      ),
      ('phone', DuoLayout.none, phone.size, phone.insets),
    ]) {
      testWidgets(name, (t) async {
        sizeWindow(t, size, insets);
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        addTearDown(c.dispose);
        await c.blobs.put('img', Uint8List.fromList(png));
        await t.pumpWidget(
          withLayout(
            layout,
            appHost(
              Scaffold(
                body: AttachmentCard(
                  controller: c,
                  item: Attachment(
                    id: 'img',
                    name: 'cat.png',
                    mime: 'image/png',
                    kind: 'image',
                  ),
                  preview: true,
                ),
              ),
            ),
          ),
        );
        await t.pump();
        await t.pump();
        await t.tap(find.byKey(const Key('attachment-thumb-img')));
        await t.pump();
        await t.pump(const Duration(seconds: 1));
        final area = t.getRect(find.byKey(const Key('attachment-viewer-area')));
        final viewer = t.getRect(find.byType(InteractiveViewer));
        final contentRight = layout.hasVerticalBar
            ? size.width - 84
            : size.width;
        expect(area.left, 0);
        expect(area.right, contentRight);
        expect(viewer.right, lessThanOrEqualTo(contentRight));
        expect(viewer.center.dx, closeTo(contentRight / 2, .5));
        if (layout.hasVerticalBar) {
          final strip = t.getRect(find.byKey(const Key('duo-rail')));
          expect(viewer.overlaps(strip), isFalse);
        }
      });
    }
  });

  group('2 sidebar grip reach', () {
    testWidgets('gives way to a horizontal scroll view under it', (t) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var visible = true;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) => SidebarSplit(
                width: 240,
                visible: visible,
                duration: Duration.zero,
                onChanged: (v) => set(() => visible = v),
                content: Center(
                  child: SizedBox(
                    height: 200,
                    child: SingleChildScrollView(
                      key: const Key('code-block'),
                      controller: scroll,
                      scrollDirection: Axis.horizontal,
                      child: const SizedBox(width: 2000, height: 200),
                    ),
                  ),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      final grip = t.getRect(find.byKey(const Key('pane-grip')));
      final reach = t.getRect(find.byKey(const Key('pane-grip-reach')));
      expect(reach.left, grip.right);
      final g = await t.startGesture(reach.center);
      for (var i = 0; i < 15; i++) {
        await g.moveBy(const Offset(-10, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(
        scroll.offset,
        greaterThan(100),
        reason: 'the code block scrolled',
      );
      expect(visible, isTrue, reason: 'the pane stayed open');
      expect(t.getRect(find.byKey(const Key('pane-grip'))).left, 240);
    });

    testWidgets('still drags the pane where nothing scrolls sideways', (
      t,
    ) async {
      var visible = true;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) => SidebarSplit(
                width: 240,
                visible: visible,
                duration: Duration.zero,
                onChanged: (v) => set(() => visible = v),
                // A vertical list under the reach, as in the chat.
                content: ListView(
                  children: [
                    for (var i = 0; i < 40; i++)
                      SizedBox(height: 40, child: Text('$i')),
                  ],
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      final reach = t.getRect(find.byKey(const Key('pane-grip-reach')));
      final g = await t.startGesture(reach.center);
      for (var i = 0; i < 15; i++) {
        await g.moveBy(const Offset(-15, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(visible, isFalse);
    });
  });

  group('3 finished-works notice', () {
    testWidgets('sits above the composer though raised beside the chat', (
      t,
    ) async {
      sizeWindow(t, phone.size, phone.insets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      final pane = GlobalKey(), composer = GlobalKey();
      await t.pumpWidget(
        appHost(
          Scaffold(
            body: Stack(
              children: [
                NoticeAnchor(
                  pane: pane,
                  composer: composer,
                  child: Builder(
                    key: pane,
                    builder: (context) => SafeArea(
                      bottom: false,
                      child: Column(
                        children: [
                          const Expanded(child: SizedBox.expand()),
                          SizedBox(
                            key: composer,
                            height: 106,
                            width: double.infinity,
                          ),
                          const SizedBox(height: 44),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: CompletedWorksPresenter(
                    controller: c,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
          brightness: Brightness.dark,
        ),
      );
      // The user is active: a notice, not the sheet.
      await t.tapAt(const Offset(200, 300));
      await t.pump();
      final task = MediaTask(
        id: 'n1',
        kind: 'image',
        prompt: 'p',
        args: {},
        status: 'queued',
      );
      c.current.tasks.add(task);
      c.notifyDraftSuggestion();
      task
        ..status = 'completed'
        ..urls = ['https://example.test/a.png'];
      c.notifyDraftSuggestion();
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('作品已生成'), findsOneWidget);
      final snack = t.getRect(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Material),
            )
            .first,
      );
      final box = t.getRect(find.byKey(composer));
      expect(snack.bottom, lessThanOrEqualTo(box.top));
      await t.pump(const Duration(seconds: 4));
      await t.pumpWidget(const SizedBox());
    });
  });

  group('4 works sheet', () {
    Future<JarvisController> openWorks(
      WidgetTester t,
      Pose pose, {
      int count = 3,
    }) async {
      sizeWindow(t, pose.size, pose.insets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      for (var i = 0; i < count; i++) {
        c.current.tasks.add(
          MediaTask(
            id: 't$i',
            kind: 'image',
            prompt: '一只猫 $i',
            args: {},
            status: 'failed',
            error: '失败',
          ),
        );
      }
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
      return c;
    }

    testWidgets('landscape: the list runs under the home indicator', (t) async {
      await openWorks(t, phoneLandscape, count: 8);
      final list = t.getRect(find.byType(ListView));
      expect(list.bottom, phoneLandscape.size.height);
      // The last card can still scroll clear of the indicator.
      final scrollable = t.state<ScrollableState>(find.byType(Scrollable));
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await t.pump();
      final last = t.getRect(find.byKey(const ValueKey('t0')));
      expect(
        last.bottom,
        lessThanOrEqualTo(
          phoneLandscape.size.height - phoneLandscape.insets.bottom,
        ),
      );
    });

    testWidgets('cards line up with the title, actions with the text', (
      t,
    ) async {
      await openWorks(t, phone);
      final title = t.getRect(find.text('生成作品'));
      final card = t.getRect(find.byKey(const ValueKey('t2')));
      expect(card.left, closeTo(title.left, .5));
      final done = t.getRect(find.byKey(const Key('works-done')));
      // 完成's label ends 12 pt inside its button, where the card's edge is.
      expect(card.right, closeTo(done.right - 12, .5));
      final prompt = t.getRect(find.text('一只猫 2'));
      final copy = t.getRect(find.byIcon(Icons.copy_outlined).first);
      expect(copy.left, closeTo(prompt.left, .5));
    });

    testWidgets('cards are built as they scroll into view', (t) async {
      await openWorks(t, phone, count: 40);
      expect(find.byType(MediaCard).evaluate().length, lessThan(20));
      expect(t.takeException(), isNull);
    });

    testWidgets('voice picker: the list runs under the home indicator', (
      t,
    ) async {
      sizeWindow(t, phoneLandscape.size, phoneLandscape.insets);
      final c = JarvisController(SpeechApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await c.connect();
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
      unawaited(showVoicePicker(host, c));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final list = t.getRect(find.byType(ListView));
      expect(list.bottom, phoneLandscape.size.height);
      final group = t.getRect(find.byType(SettingsGroup));
      final scrollable = t.state<ScrollableState>(find.byType(Scrollable));
      if (scrollable.position.maxScrollExtent > 0) {
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await t.pump();
      }
      expect(
        t.getRect(find.byType(SettingsGroup)).bottom,
        lessThanOrEqualTo(
          phoneLandscape.size.height - phoneLandscape.insets.bottom,
        ),
        reason: '$group',
      );
      // Connecting saved the server's default voice: let the save run.
      await t.pump(const Duration(seconds: 1));
    });
  });

  group('5 action menus keep 8 pt off the edges', () {
    for (final pose in [
      phone,
      const Pose('SE', Size(375, 667), EdgeInsets.only(top: 20)),
      phoneLandscape,
    ]) {
      testWidgets(pose.name, (t) async {
        sizeWindow(t, pose.size, pose.insets);
        await t.pumpWidget(
          appHost(
            Scaffold(
              appBar: AppBar(
                leading: JarvisActionMenu(
                  tooltip: '左',
                  actions: const [JarvisMenuAction('a', '一个相当长的操作名称')],
                  onSelected: (_) {},
                ),
                actions: [
                  JarvisActionMenu(
                    tooltip: '更多操作',
                    actions: const [
                      JarvisMenuAction('settings', '设置', icon: Icons.tune),
                      JarvisMenuAction('status', '模型状态'),
                    ],
                    onSelected: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        for (final tooltip in ['更多操作', '左']) {
          await t.tap(find.byTooltip(tooltip));
          await t.pump();
          await t.pump(const Duration(milliseconds: 200));
          final surface = t.getRect(
            find
                .descendant(
                  of: find.byKey(const Key('action-menu-margin')),
                  matching: find.byType(Material),
                )
                .first,
          );
          final trigger = t.getRect(
            find.ancestor(
              of: find.byTooltip(tooltip),
              matching: find.byType(IconButton),
            ),
          );
          final safe = pose.safe;
          expect(surface.right, lessThanOrEqualTo(safe.right - 8 + .01));
          expect(surface.left, greaterThanOrEqualTo(safe.left + 8 - .01));
          // Still hanging off the trigger: directly below it.
          expect(surface.top, closeTo(trigger.bottom, .5), reason: tooltip);
          JarvisActionMenu.closeOpen();
          await t.pump();
          await t.pump(const Duration(milliseconds: 200));
        }
      });
    }
  });

  group('6 call header', () {
    testWidgets('phone on its side: pill and hang up clear the top edge', (
      t,
    ) async {
      await pumpVoice(
        t,
        size: phoneLandscape.size,
        insets: phoneLandscape.insets,
      );
      expect(
        t.getRect(find.byKey(const Key('voice-name'))).top,
        greaterThanOrEqualTo(8),
      );
      expect(t.getRect(find.byTooltip('结束语音通话')).top, greaterThanOrEqualTo(8));
      expect(t.takeException(), isNull);
    });

    for (final (name, layout, size, insets, safeTop) in [
      (
        'outer',
        outerDisplay,
        const Size(466, 678),
        const EdgeInsets.only(right: 84, bottom: 34),
        0.0,
      ),
      (
        'outer landscape',
        outerLandscape,
        const Size(678, 466),
        const EdgeInsets.only(right: 84, bottom: 21),
        0.0,
      ),
      (
        'inner landscape',
        flatLandscape,
        const Size(951, 669),
        const EdgeInsets.only(right: 84, bottom: 34),
        0.0,
      ),
      (
        'inner portrait',
        DuoLayout.fromMap({
          'edge': 'none',
          'width': 669.0,
          'height': 951.0,
          'safe': {'left': 0.0, 'top': 54.0, 'right': 0.0, 'bottom': 34.0},
          'regions': [
            {
              'kind': 'division',
              'active': false,
              'x': 0.0,
              'y': 455.5,
              'w': 669.0,
              'h': 40.0,
            },
          ],
        }),
        const Size(669, 951),
        const EdgeInsets.only(top: 54, bottom: 34),
        54.0,
      ),
    ]) {
      testWidgets('Duo $name: the pill sits on the chat header axis', (
        t,
      ) async {
        await pumpVoice(t, size: size, insets: insets, layout: layout);
        expect(
          t.getRect(find.byKey(const Key('voice-name'))).center.dy,
          closeTo(safeTop + layout.headerAxisY, .5),
        );
        expect(t.takeException(), isNull);
      });
    }
  });

  group('7 call controls share one height', () {
    for (final pose in [phone, phoneLandscape]) {
      testWidgets(pose.name, (t) async {
        await pumpVoice(t, size: pose.size, insets: pose.insets);
        final selector = t.getSize(find.byType(VoiceModeSelector)).height;
        final talk = t
            .getSize(find.byKey(const Key('voice-hold-surface')))
            .height;
        expect(selector, talk);
        for (final id in ['ptt', 'vad']) {
          expect(
            t.getSize(find.byKey(ValueKey('voice-mode-$id'))).height,
            greaterThanOrEqualTo(44),
          );
        }
      });
    }
  });

  group('8 status page', () {
    testWidgets('hairlines start under the names, heading at 8 pt', (t) async {
      sizeWindow(t, phone.size, phone.insets);
      final c = JarvisController(StatusApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await t.pumpWidget(appHost(StatusPage(controller: c)));
      await t.pump();
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final card = t.getRect(find.byType(SettingsGroup));
      final name = t.getRect(find.text('语音'));
      expect(name.left - card.left, statusTextIndent);
      final divider = t.widget<Divider>(find.byType(Divider).first);
      expect(divider.indent, statusTextIndent);
      final heading = t.getRect(find.byKey(const Key('status-heading')));
      final title = t.getRect(
        find
            .descendant(
              of: find.byKey(const Key('status-heading')),
              matching: find.byType(Text),
            )
            .first,
      );
      expect(heading.left, card.left);
      expect(title.left - card.left, 8);
    });
  });

  group('9 settings alignment', () {
    testWidgets('voice names, their hairlines and the engine row', (t) async {
      await t.pumpWidget(
        appHost(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: SettingsGroup(
                children: [
                  PickerRow<String>(
                    label: '语音引擎',
                    value: 'a',
                    options: const [('a', 'A')],
                    onSelected: (_) {},
                  ),
                  for (final (n, s) in [('星衡', true), ('晨曦', false)])
                    VoiceChoiceRow(
                      name: n,
                      description: '',
                      selected: s,
                      playing: false,
                      onSelect: () {},
                      onPlay: () {},
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      final card = t.getRect(find.byType(SettingsGroup));
      for (final n in ['星衡', '晨曦']) {
        expect(t.getRect(find.text(n)).left - card.left, 56);
      }
      expect(t.getRect(find.text('语音引擎')).left - card.left, 16);
      final dividers = t.widgetList<Divider>(find.byType(Divider)).toList();
      expect(dividers.map((d) => d.indent), [16, 56]);
      // No tint across the chosen row: the check mark marks it.
      for (final tile in t.widgetList<ListTile>(find.byType(ListTile))) {
        expect(tile.selectedTileColor, isNull);
      }
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('iOS slider track runs from the name to the value', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: themeFor(Brightness.light)
              .copyWith(platform: TargetPlatform.iOS),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: SettingsGroup(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SliderHeader(title: '聊天字号', value: '50%'),
                        SettingsSlider(
                          child: Slider.adaptive(value: .5, onChanged: (_) {}),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final slider = t.getRect(find.byType(CupertinoSlider));
      final name = t.getRect(find.text('聊天字号'));
      final value = t.getRect(find.text('50%'));
      // The track is 8 pt inside the slider's box.
      expect(slider.left + 8, closeTo(name.left, .5));
      expect(slider.right - 8, closeTo(value.right, .5));
    });

    testWidgets('a value ending in a full-width bracket ends flush', (t) async {
      await t.pumpWidget(
        appHost(
          const Scaffold(
            body: Column(
              children: [
                SliderHeader(title: '聊天字号', value: '16（默认）'),
                SliderHeader(title: '聊天字号', value: '16（默认'),
              ],
            ),
          ),
        ),
      );
      final full = t.getRect(find.text('16（默认）'));
      final open = t.getRect(find.text('16（默认'));
      final size = t.widget<Text>(find.text('16（默认）')).style?.fontSize ?? 16;
      // The closing bracket adds only its inked half.
      expect(full.width - open.width, closeTo(size / 2, .5));
      expect(full.right, open.right);
    });
  });

  group('10 privacy paragraphs', () {
    test('the last two characters are joined', () {
      expect(noOrphan('并附上相关的对话内容。'), '并附上相关的对话内⁠容。');
      expect(noOrphan('你输入的文字。'), '你输入的文⁠字。');
      expect(noOrphan('服务器 example.com'), '服务器 example.com');
    });

    testWidgets('a wrap never leaves one character alone', (t) async {
      const text = '如果回复含有不当或有害的内容，请联系你的服务提供者，并附上相关的对话内容。';
      const style = TextStyle(fontSize: 10);
      int lastLine(String value, double width) {
        final painter = TextPainter(
          text: TextSpan(text: value, style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: width);
        final lines = painter.computeLineMetrics();
        final end = painter.getPositionForOffset(
          Offset(0, lines.last.baseline - 1),
        );
        final rest = value.substring(end.offset).replaceAll('\u2060', '');
        painter.dispose();
        return rest.length;
      }

      // Widths at which the plain text leaves "容。" alone on its last line.
      var orphaned = 0;
      for (var width = 60.0; width < 400; width += 5) {
        if (lastLine(text, width) > 2) continue;
        orphaned++;
        expect(
          lastLine(noOrphan(text), width),
          greaterThanOrEqualTo(3),
          reason: 'at $width',
        );
      }
      expect(orphaned, greaterThan(0), reason: 'the setup orphans');
    });
  });
}

class StatusApi extends FakeApi {
  @override
  Future<Map<String, dynamic>> toolsStatus() async => {
    'data': [
      {'name': '语音', 'state': 'ready'},
      {'name': '图片', 'state': 'loading'},
    ],
  };
}
