import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/adaptive_layout.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/model/starters.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/voice/audio_device.dart' show AudioDevice;
import 'package:jarvis_android/ui/duo_rail.dart';
import 'package:jarvis_android/ui/hugging_icon_button.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/login_art.dart' show JarvisMark;
import 'package:jarvis_android/ui/media_widgets.dart';
import 'package:jarvis_android/ui/call_controls.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/status_page.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/voice_page.dart';

import 'support.dart';
import 'voice_layout_test.dart' show LayoutApi, settleTask;
import 'voice_support.dart';

// Values read from the iPhone Duo simulator (inner display, landscape, iOS 27.1).
final duoLandscape = DuoLayout.fromMap({
  'edge': 'right',
  'width': 951.0,
  'height': 669.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
  'regions': [
    {
      'kind': 'division',
      'active': false,
      'x': 455.5,
      'y': 0.0,
      'w': 40.0,
      'h': 669.0,
    },
    {
      'kind': 'occlusion',
      'active': true,
      'x': 867.0,
      'y': 0.0,
      'w': 84.0,
      'h': 124.0,
    },
  ],
});

// Values read from the iPhone Duo simulator (outer display, closed): no fold region there.
final duoOuter = DuoLayout.fromMap({
  'edge': 'right',
  'width': 466.0,
  'height': 678.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
  'regions': [
    {
      'kind': 'occlusion',
      'active': true,
      'x': 382.0,
      'y': 0.0,
      'w': 84.0,
      'h': 174.0,
    },
  ],
});

Future<JarvisController> pumpHome(
  WidgetTester t,
  DuoLayout layout, {
  double keyboard = 0,
  Size size = const Size(951, 669),
  EdgeInsets? insets,
  void Function(JarvisController)? seed,
  TargetPlatform? platform,
  AudioDevice? audio,
  FakeApi? api,
  ValueNotifier<DuoLayout>? notifier,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  final safe = insets ?? layout.safe;
  t.view.padding = FakeViewPadding(right: safe.right, bottom: safe.bottom);
  t.view.viewPadding = t.view.padding;
  t.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(t.view.resetPadding);
  addTearDown(t.view.resetViewPadding);
  addTearDown(t.view.resetViewInsets);
  final c = audio == null
      ? JarvisController(api ?? FakeApi(), MemoryVault())
      : JarvisController(api ?? FakeApi(), MemoryVault(), audioDevice: audio);
  await c.initialize();
  addTearDown(c.dispose);
  seed?.call(c);
  await t.pumpWidget(
    DuoLayoutScope(
      layout: notifier ?? ValueNotifier(layout),
      child: MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
        home: JarvisHome(controller: c),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 400));
  return c;
}

void main() {
  testWidgets('Vertical bar: chat controls move into the right strip', (
    t,
  ) async {
    await pumpHome(t, duoLandscape);
    final strip = t.getRect(find.byKey(const Key('duo-rail')));
    expect(strip.left, 867);
    expect(strip.width, 84);
    expect(
      strip.top,
      124,
      reason: 'starts below the status / Dynamic Island area',
    );
    expect(strip.bottom, 669 - 34, reason: 'stays above the home indicator');
    // Top toolbar buttons at the top of the strip, bottom ones at the bottom.
    final sidebar = t.getRect(find.byKey(const Key('duo-rail-sidebar')));
    final newChat = t.getRect(find.byKey(const Key('duo-rail-new-chat')));
    final settings = t.getRect(find.byKey(const Key('duo-rail-settings')));
    expect(sidebar.top, 124);
    expect(newChat.top, greaterThan(sidebar.top));
    expect(settings.bottom, strip.bottom);
    for (final r in [sidebar, newChat, settings]) {
      expect(strip.contains(r.center), isTrue);
    }
    // Nothing is left in the old places.
    // The only menu icon on screen is the rail's own sidebar button.
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('duo-rail')),
        matching: find.byIcon(Icons.menu),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('start-new-chat')), findsNothing);
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(find.widgetWithText(ListTile, '设置'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('Without a vertical bar the chat header is unchanged', (t) async {
    await pumpHome(t, DuoLayout.none);
    expect(find.byKey(const Key('duo-rail')), findsNothing);
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.byKey(const Key('start-new-chat')), findsOneWidget);
    expect(find.byTooltip('更多操作'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '设置'), findsOneWidget);
  });

  testWidgets(
    'Rail settings opens the settings page, whose back is in the rail',
    (t) async {
      await pumpHome(t, duoLandscape);
      await t.tap(find.byKey(const Key('duo-rail-settings')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      expect(find.byKey(const Key('duo-rail-back')), findsOneWidget);
      await t.tap(find.byKey(const Key('duo-rail-back')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(SettingsPage), findsNothing);
    },
  );

  testWidgets(
    'Short strip (keyboard up) overflows the lower controls into a menu',
    (t) async {
      await pumpHome(t, duoLandscape, keyboard: 400);
      expect(find.byKey(const Key('duo-rail-overflow')), findsOneWidget);
      expect(find.byKey(const Key('duo-rail-settings')), findsNothing);
      await t.tap(find.byKey(const Key('duo-rail-overflow')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('设置'), findsOneWidget);
    },
  );

  testWidgets('Voice page: close and end-call move into the strip', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(951, 669);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    t.view.padding = const FakeViewPadding(right: 84, bottom: 34);
    t.view.viewPadding = t.view.padding;
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewPadding);
    final c = JarvisController(
      FakeApi(),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await c.initialize();
    addTearDown(c.dispose);
    c.voice.owner = c.current;
    await t.pumpWidget(
      DuoLayoutScope(
        layout: ValueNotifier(duoLandscape),
        child: MaterialApp(home: VoicePage(controller: c)),
      ),
    );
    await t.pump();
    final strip = t.getRect(find.byKey(const Key('duo-rail')));
    for (final id in ['collapse', 'hangup']) {
      final r = t.getRect(find.byKey(Key('duo-rail-$id')));
      expect(strip.contains(r.center), isTrue, reason: id);
    }
    // Only one of each control exists (none left in the header corners).
    expect(find.byTooltip('结束语音通话'), findsOneWidget);
    expect(find.byTooltip('收起通话界面'), findsOneWidget);
    expect(find.byType(HangupButton), findsOneWidget);
    // The voice name stays centered in the content area left of the strip.
    expect(
      t.getRect(find.byKey(const Key('voice-name'))).center.dx,
      closeTo((951 - 84) / 2, 1),
    );
    expect(t.takeException(), isNull);
  });

  for (final active in [true, false]) {
    testWidgets(
      'Voice controls ${active ? 'avoid' : 'ignore'} the ${active ? 'active' : 'inactive'} fold',
      (t) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = const Size(951, 669);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.view.resetPhysicalSize);
        t.view.padding = const FakeViewPadding(right: 84, bottom: 34);
        t.view.viewPadding = t.view.padding;
        addTearDown(t.view.resetPadding);
        addTearDown(t.view.resetViewPadding);
        final folded = DuoLayout.fromMap({
          'edge': 'right',
          'width': 951.0,
          'height': 669.0,
          'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
          'regions': [
            {
              'kind': 'division',
              'active': active,
              'x': 455.5,
              'y': 0.0,
              'w': 40.0,
              'h': 669.0,
            },
            {
              'kind': 'occlusion',
              'active': true,
              'x': 867.0,
              'y': 0.0,
              'w': 84.0,
              'h': 124.0,
            },
          ],
        });
        final c = JarvisController(
          FakeApi(),
          MemoryVault(),
          audioDevice: FakeAudio(),
        );
        await c.initialize();
        addTearDown(c.dispose);
        c.voice.owner = c.current;
        await t.pumpWidget(
          DuoLayoutScope(
            layout: ValueNotifier(folded),
            child: MaterialApp(home: VoicePage(controller: c)),
          ),
        );
        await t.pump();
        final split = find.byKey(const Key('voice-controls-fold-split'));
        if (!active) {
          expect(split, findsNothing);
          return;
        }
        expect(split, findsOneWidget);
        final band = folded.verticalFold!;
        final talk = t.getRect(find.byKey(const Key('voice-talk')));
        final ptt = t.getRect(find.byKey(const ValueKey('voice-mode-ptt')));
        final vad = t.getRect(find.byKey(const ValueKey('voice-mode-vad')));
        expect(talk.left, greaterThanOrEqualTo(band.right));
        expect(ptt.right, lessThanOrEqualTo(band.left));
        expect(vad.right, lessThanOrEqualTo(band.left));
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Outer display: composer gap is the same left, right and bottom',
    (t) async {
      await pumpHome(t, duoOuter, size: const Size(466, 678));
      final frame = t.getRect(find.byKey(const Key('composer-frame')));
      expect(frame.left, DuoLayout.edgeGap);
      expect(
        382 - frame.right,
        DuoLayout.edgeGap,
        reason: 'right gap to the vertical strip',
      );
      expect(
        678 - frame.bottom,
        DuoLayout.edgeGap,
        reason: 'flush to the bottom edge, not above the home indicator inset',
      );
    },
  );

  testWidgets(
    'Unfolded screen: composer is ~10% narrower, flush to the bottom, messages in a centred column inside it',
    (t) async {
      // Same window and insets, but no Duo layout: the default spacing is kept.
      await pumpHome(t, DuoLayout.none, insets: duoLandscape.safe);
      final plain = t.getRect(find.byKey(const Key('composer-frame')));
      expect(
        669 - plain.bottom,
        10 + 34,
        reason: 'default: 10 plus the home indicator inset',
      );
      await pumpHome(
        t,
        duoLandscape,
        seed: (c) => c.current.messages.addAll([
          ChatMessage('user', '你好'),
          ChatMessage('assistant', '你好，我是贾维斯'),
        ]),
      );
      final folded = t.getRect(find.byKey(const Key('composer-frame')));
      // The message column is the composer frame narrowed equally on both sides: the model's text starts at its left
      // edge (text stays left-aligned), your bubble ends at its right edge.
      final side = folded.width * (1 - DuoLayout.replyWidthFactor) / 2;
      expect(
        t.getRect(find.text('你好，我是贾维斯')).left,
        closeTo(folded.left + side, 1),
      );
      expect(
        t.getRect(find.text('你好')).right + 16,
        closeTo(folded.right - side, 1),
        reason: 'user bubble (16pt inner padding) ends at the column edge',
      );
      expect(
        folded.width + 2 * DuoLayout.edgeGap,
        closeTo(DuoLayout.dockedContentFactor * (plain.width + 2 * 10), 1),
      );
      expect(669 - folded.bottom, DuoLayout.edgeGap);
      expect(
        folded.height,
        plain.height + 8,
        reason: 'the composer is 8pt taller on a foldable',
      );
    },
  );

  testWidgets(
    'Unfolded screen: collapsing the session list widens content and composer further',
    (t) async {
      await pumpHome(t, duoLandscape);
      final open = t.getRect(find.byKey(const Key('composer-frame')));
      await t.tap(find.byTooltip('收起会话'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final closed = t.getRect(find.byKey(const Key('composer-frame')));
      expect(find.byTooltip('展开会话'), findsOneWidget);
      expect(closed.width, greaterThan(open.width * 1.1));
      expect(closed.center.dx, closeTo((951 - 84) / 2, 1));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('Unfolded screen: sidebar brand and chat header share one axis', (
    t,
  ) async {
    await pumpHome(t, duoLandscape);
    final brand = t.getCenter(find.text('JARVIS'));
    final title = t.getCenter(find.byKey(const Key('chat-heading-line')));
    expect(brand.dy, closeTo(DuoLayout.headerAxis, 0.5));
    expect(title.dy, closeTo(DuoLayout.headerAxis, 0.5));
    final mark = t.getCenter(find.byType(JarvisMark).first);
    expect(mark.dy, closeTo(DuoLayout.headerAxis, 0.5));
  });

  testWidgets(
    'iOS: a short welcome page still follows the finger (rubber band)',
    (t) async {
      await pumpHome(t, DuoLayout.none, size: const Size(466, 900));
      final greeting = find.byKey(const ValueKey('starter-0'));
      final before = t.getRect(greeting).top;
      final drag = await t.startGesture(const Offset(200, 300));
      await drag.moveBy(const Offset(0, 80));
      await t.pump();
      expect(t.getRect(greeting).top, greaterThan(before + 10));
      await drag.up();
      await t.pump();
      await t.pump(const Duration(seconds: 2));
      expect(t.getRect(greeting).top, closeTo(before, 1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('Android: a short welcome page does not move (unchanged)', (
    t,
  ) async {
    await pumpHome(t, DuoLayout.none, size: const Size(466, 900));
    final greeting = find.byKey(const ValueKey('starter-0'));
    final before = t.getRect(greeting).top;
    final drag = await t.startGesture(const Offset(200, 300));
    await drag.moveBy(const Offset(0, 80));
    await t.pump();
    expect(t.getRect(greeting).top, before);
    await drag.up();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Outer screen: the sidebar button opens and closes the drawer', (
    t,
  ) async {
    await pumpHome(t, duoOuter, size: const Size(466, 678));
    expect(find.byTooltip('展开会话'), findsOneWidget);
    await t.tap(find.byTooltip('展开会话'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('conversation-list')), findsOneWidget);
    expect(find.byTooltip('收起会话'), findsOneWidget);
    await t.tap(find.byTooltip('收起会话'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('conversation-list')), findsNothing);
    expect(find.byTooltip('展开会话'), findsOneWidget);
  });

  testWidgets('Foldable header: the whole title row opens the model status', (
    t,
  ) async {
    await pumpHome(t, duoLandscape);
    final title = t.getRect(find.byKey(const ValueKey('chat-heading-line')));
    final dot = t.getRect(find.byKey(const Key('connection-dot')));
    expect(dot.width, inInclusiveRange(8, 10));
    expect(dot.left, greaterThanOrEqualTo(title.right));
    final row = t.getRect(
      find
          .ancestor(
            of: find.byKey(const Key('connection-dot')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(row.height, greaterThanOrEqualTo(44));
    expect(row.width, greaterThanOrEqualTo(44));
    expect(row.contains(title.center), isTrue);
    expect(row.contains(dot.center), isTrue);
    // The name opens the status page, and so does the dot.
    await t.tapAt(title.center);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(StatusPage), findsOneWidget);
    t.state<NavigatorState>(find.byType(Navigator).first).pop();
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.byKey(const Key('connection-dot')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(StatusPage), findsOneWidget);
  });

  testWidgets('Chat: image and video cards are as wide as your own messages', (
    t,
  ) async {
    final c = await pumpHome(
      t,
      duoLandscape,
      size: const Size(951, 669),
      seed: (c) {
        final task = MediaTask(
          id: 'v1',
          kind: 'video',
          prompt: '一只猫',
          args: {},
          status: 'completed',
          urls: ['/v1/videos/job/content'],
        );
        c.current.tasks.add(task);
        c.current.messages.addAll([
          ChatMessage('user', '很长的话。' * 80),
          ChatMessage('tool', task.prompt, taskId: task.id),
        ]);
      },
    );
    final mine = t.getRect(
      find.byKey(
        ValueKey('bubble-${c.current.id}-${c.current.messages.first.id}'),
      ),
    );
    final card = t.getRect(find.byType(MediaCard));
    expect(card.width, closeTo(mine.width, 1));
  });

  for (final entry in {
    'unfolded': (duoLandscape, const Size(951, 669)),
    'outer': (duoOuter, const Size(466, 678)),
  }.entries) {
    testWidgets(
      'Foldable ${entry.key}: messages form one column centred on the composer, narrowed on both sides',
      (t) async {
        final c = await pumpHome(
          t,
          entry.value.$1,
          size: entry.value.$2,
          seed: (c) => c.current.messages.addAll([
            ChatMessage('user', '你好'),
            ChatMessage('assistant', '很长的回复。' * 24),
          ]),
        );
        final frame = t.getRect(find.byKey(const Key('composer-frame')));
        final messages = c.current.messages;
        final reply = t.getRect(
          find.byKey(ValueKey('bubble-${c.current.id}-${messages.last.id}')),
        );
        final mine = t.getRect(
          find.byKey(ValueKey('bubble-${c.current.id}-${messages.first.id}')),
        );
        final column = frame.width * DuoLayout.replyWidthFactor;
        final side = (frame.width - column) / 2;
        expect(reply.width, closeTo(column, 2));
        expect(
          reply.center.dx,
          closeTo(frame.center.dx, 1),
          reason: 'the reply column is centred like the composer',
        );
        expect(reply.left - frame.left, closeTo(side, 1));
        expect(
          frame.right - mine.right,
          closeTo(side, 1),
          reason: 'your bubble ends at the same symmetric edge',
        );
      },
    );
  }

  for (final entry in {
    'unfolded': (duoLandscape, const Size(951, 669)),
    'outer': (duoOuter, const Size(466, 678)),
  }.entries) {
    testWidgets(
      'Foldable ${entry.key}: the "call in progress" banner is exactly as wide as the composer frame',
      (t) async {
        final c = await pumpHome(
          t,
          entry.value.$1,
          size: entry.value.$2,
          audio: FakeAudio(),
          api: LayoutApi(),
        );
        await c.login('user', 'test');
        await settleTask(t, c.voice.start(c.current));
        c.voice.minimize();
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        final banner = find.ancestor(
          of: find.text('语音通话中'),
          matching: find.byType(Container),
        );
        expect(banner, findsWidgets);
        final frame = t.getRect(find.byKey(const Key('composer-frame')));
        final rect = t.getRect(banner.first);
        expect(rect.left, closeTo(frame.left, 1));
        expect(rect.right, closeTo(frame.right, 1));
        await t.pumpWidget(const SizedBox());
        await settleTask(t, c.voice.stop());
        await t.pump(const Duration(seconds: 1));
      },
    );
  }

  testWidgets('Foldable: copy / regenerate hug the reply text', (t) async {
    final c = await pumpHome(
      t,
      duoLandscape,
      seed: (c) => c.current.messages.addAll([
        ChatMessage('user', '你好'),
        ChatMessage('assistant', '你好，我是贾维斯'),
      ]),
    );
    final bubble = t.getRect(
      find.byKey(
        ValueKey('bubble-${c.current.id}-${c.current.messages.last.id}'),
      ),
    );
    final copy = t.getRect(find.byTooltip('复制回复'));
    final again = t.getRect(find.byTooltip('重新生成'));
    expect(copy.size, const Size(44, 44), reason: '复制键的点按区域至少 44pt 宽');
    // The 16pt copy icon sits at the left of its tap area: its left edge is the text's left edge.
    expect(copy.left, closeTo(bubble.left, 1));
    expect(again.left, closeTo(copy.right, 1), reason: 'buttons are packed');
    // The press circle is drawn around the box that holds the icon, so it is concentric with the icon.
    final copyButton = find.widgetWithIcon(
      HuggingIconButton,
      Icons.copy_outlined,
    );
    final ink = t.getCenter(
      find.descendant(of: copyButton, matching: find.byType(InkResponse)),
    );
    final icon = t.getCenter(
      find.descendant(
        of: copyButton,
        matching: find.byIcon(Icons.copy_outlined),
      ),
    );
    expect(ink, icon);
    // Regenerate has a 44pt-wide tap area too, its icon at the left of it.
    expect(again.size, const Size(44, 44));
    // The whole copy button is tappable, including its left edge.
    await t.tapAt(Offset(copy.left + 2, copy.center.dy));
    await t.pump();
  });

  group('splitDuoRail', () {
    DuoRailAction a(String id) => DuoRailAction(
      id: id,
      icon: Icons.circle,
      symbol: 'circle',
      label: id,
      onPressed: () {},
    );
    final top = [a('t1'), a('t2')], bottom = [a('b1'), a('b2')];
    List<String> ids(List<DuoRailAction> l) => [for (final x in l) x.id];

    test('everything fits: groups untouched', () {
      final s = splitDuoRail(top, bottom, 4 * 58, extent: 58);
      expect(ids(s.top), ['t1', 't2']);
      expect(ids(s.bottom), ['b1', 'b2']);
      expect(s.overflow, isEmpty);
    });

    test('short strip: bottom items overflow first, one slot is the menu', () {
      final s = splitDuoRail(top, bottom, 3 * 58, extent: 58);
      expect(ids(s.top), ['t1', 't2']);
      expect(s.bottom, isEmpty);
      expect(ids(s.overflow), ['b1', 'b2']);
      final tiny = splitDuoRail(top, bottom, 1.5 * 58, extent: 58);
      expect(tiny.top, isEmpty);
      expect(ids(tiny.overflow), ['t1', 't2', 'b1', 'b2']);
    });

    test('no room at all: nothing is shown', () {
      final s = splitDuoRail(top, bottom, 30, extent: 58);
      expect(s.top, isEmpty);
      expect(s.bottom, isEmpty);
      expect(s.overflow, isEmpty);
    });
  });

  testWidgets(
    'On iOS the strip is the native Liquid Glass view with SF Symbols',
    (t) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final created = <Map<Object?, Object?>>[];
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          (call) async {
            if (call.method == 'create') {
              created.add(call.arguments as Map<Object?, Object?>);
            }
            return null;
          },
        );
        addTearDown(
          () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform_views,
            null,
          ),
        );
        await pumpHome(t, duoLandscape);
        expect(find.byType(UiKitView), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('duo-rail')),
            matching: find.byType(IconButton),
          ),
          findsNothing,
          reason: 'no Flutter buttons in the strip',
        );
        expect(created, hasLength(1));
        expect(created.single['viewType'], 'ai.jarvis.app/duo-rail');
        // creationParams are encoded; the readable parts are enough to check the symbols were passed.
        final params = created.single['params'];
        final bytes = params is ByteData
            ? params.buffer.asUint8List()
            : (params as List<int>);
        final text = String.fromCharCodes(
          bytes.where((b) => b >= 32 && b < 127),
        );
        for (final symbol in [
          'sidebar.leading',
          'square.and.pencil',
          'gearshape',
        ]) {
          expect(text, contains(symbol));
        }
        // The model status lives in the header dot, not in the strip.
        expect(text, isNot(contains('waveform.path.ecg')));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'On iOS the strip lines up with the system bar buttons (not the strip centre)',
    (t) async {
      // Measured from an invisible system UINavigationBar on the simulator: its buttons are centred at x=903 (the strip
      // spans 867..951, centre 909), y=148 (top) and y=621 (bottom).
      final aligned = DuoLayout.fromMap({
        'edge': 'right',
        'width': 951.0,
        'height': 669.0,
        'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
        'systemBar': {'cx': 903.0, 'top': 148.0, 'bottom': 621.0},
        'regions': [
          {
            'kind': 'occlusion',
            'active': true,
            'x': 867.0,
            'y': 0.0,
            'w': 84.0,
            'h': 124.0,
          },
        ],
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async => null,
      );
      try {
        await pumpHome(t, aligned);
        final rail = t.getRect(find.byKey(const Key('duo-rail')));
        expect(
          rail.center.dx,
          903,
          reason: 'same centre line as the status area and system buttons',
        );
        expect(
          rail.top + 24,
          148,
          reason: 'first button centre = system top button centre',
        );
        expect(
          rail.bottom - 24,
          621,
          reason: 'last button centre = system bottom button centre',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'Settings scroll to the bottom edge with a soft fade on a foldable (no hard cut)',
    (t) async {
      Future<Rect> scrollRect(DuoLayout layout) async {
        await t.pumpWidget(const SizedBox()); // drop the previous run's routes
        await pumpHome(t, layout, insets: duoLandscape.safe);
        await t.tap(
          layout.hasVerticalBar
              ? find.byKey(const Key('duo-rail-settings'))
              : find.widgetWithText(ListTile, '设置'),
        );
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        // Settings builds its sections over the first frames of the push.
        await t.pump();
        return t.getRect(find.byKey(const Key('settings-scroll')));
      }

      final folded = await scrollRect(duoLandscape);
      expect(
        folded.bottom,
        669,
        reason: 'runs under the home-indicator inset to the screen edge',
      );
      expect(find.byKey(const Key('soft-bottom-edge')), findsOneWidget);
      // The last control can still scroll clear of the home indicator.
      await t.drag(
        find.byKey(const Key('settings-scroll')),
        const Offset(0, -3000),
      );
      await t.pump();
      final logout = find.text('退出登录');
      if (logout.evaluate().isNotEmpty) {
        expect(t.getRect(logout).bottom, lessThanOrEqualTo(669 - 34));
      }

      final plain = await scrollRect(DuoLayout.none);
      expect(
        plain.bottom,
        669 - 34,
        reason: 'Android and phones without a home indicator keep the safe-area clip',
      );
      expect(find.byKey(const Key('soft-bottom-edge')), findsNothing);
    },
  );

  group('Voice page bottom', () {
    Future<void> pumpVoice(
      WidgetTester t,
      DuoLayout layout,
      Size size, {
      bool works = false,
    }) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      t.view.padding = FakeViewPadding(
        right: duoLandscape.safe.right,
        bottom: duoLandscape.safe.bottom,
      );
      t.view.viewPadding = t.view.padding;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewPadding);
      final c = JarvisController(
        FakeApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      await c.initialize();
      addTearDown(c.dispose);
      c.voice.owner = c.current;
      if (works) {
        c.current.tasks.add(
          MediaTask(id: 'task', kind: 'video', prompt: '测试', args: {}),
        );
      }
      await t.pumpWidget(
        DuoLayoutScope(
          layout: ValueNotifier(layout),
          child: MaterialApp(home: VoicePage(controller: c)),
        ),
      );
      await t.pump();
    }

    testWidgets(
      'foldable: controls are flush to the bottom, same gap as the sides',
      (t) async {
        await pumpVoice(t, duoOuter, const Size(466, 678));
        final talk = t.getRect(find.byKey(const Key('voice-talk')));
        expect(talk.left, 20);
        expect(382 - talk.right, 20, reason: 'to the vertical strip');
        expect(
          678 - talk.bottom,
          20,
          reason: 'to the bottom edge, no extra 34pt',
        );
      },
    );

    testWidgets('unfolded: the call content is as wide as the chat column', (
      t,
    ) async {
      await pumpVoice(t, duoLandscape, const Size(951, 669));
      final sidebar = AdaptiveLayout.forWindow(
        951,
        669,
        horizontalInsets: 84,
        verticalInsets: 34,
      ).sidebarWidth;
      final stage = t.getRect(find.byType(VoiceIdentityStage));
      expect(
        stage.width + 2 * DuoLayout.edgeGap,
        closeTo(DuoLayout.collapsedColumnWidth(951 - 84, sidebar), 1),
      );
      expect(stage.center.dx, closeTo((951 - 84) / 2, 1));
    });

    testWidgets('other devices keep the safe-area spacing', (t) async {
      // Landscape: the talk button is the lowest control.
      await pumpVoice(t, DuoLayout.none, const Size(900, 600));
      final talk = t.getRect(find.byKey(const Key('voice-talk')));
      expect(600 - talk.bottom, 8 + 34);
    });

    testWidgets('a plain phone upright: hang up is the lowest control', (
      t,
    ) async {
      await pumpVoice(t, DuoLayout.none, const Size(466, 678));
      final talk = t.getRect(find.byKey(const Key('voice-talk')));
      final hangup = t.getRect(find.byTooltip('结束语音通话'));
      expect(678 - hangup.bottom, 12 + 34);
      expect(hangup.top - talk.bottom, greaterThanOrEqualTo(12));
    });

    testWidgets('foldable: the works row clears the home indicator', (t) async {
      // Inner portrait: no vertical strip, so the works row is on the page.
      final portrait = DuoLayout.fromMap({
        'edge': 'none',
        'width': 669.0,
        'height': 951.0,
        'safe': {'left': 0.0, 'top': 0.0, 'right': 0.0, 'bottom': 34.0},
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
      });
      await pumpVoice(t, portrait, const Size(669, 951), works: true);
      final row = t.getRect(find.widgetWithText(ListTile, '生成作品 · 1'));
      expect(
        row.bottom,
        951 - 34,
        reason: 'row ends above the home indicator inset',
      );
      expect(find.byKey(const Key('voice-talk')), findsOneWidget);
    });

    testWidgets('with the vertical strip the page has no second works row', (
      t,
    ) async {
      await pumpVoice(t, duoOuter, const Size(466, 678), works: true);
      expect(find.widgetWithText(ListTile, '生成作品 · 1'), findsNothing);
      expect(find.byKey(const Key('duo-rail-works')), findsOneWidget);
    });
  });

  group('Chat heading', () {
    void seedTitle(JarvisController c) {
      c.current.title = '关于折叠屏的会话';
      c.current.messages.add(ChatMessage('user', '你好'));
    }

    testWidgets(
      'foldable: only the conversation name, clear of the rounded corner',
      (t) async {
        await pumpHome(
          t,
          duoOuter,
          size: const Size(466, 678),
          seed: seedTitle,
        );
        final line = find.byKey(const ValueKey('chat-heading-line'));
        expect(
          find.descendant(of: line, matching: find.text('JARVIS')),
          findsNothing,
        );
        final name = t.getRect(
          find.descendant(of: line, matching: find.text('关于折叠屏的会话')),
        );
        expect(
          name.left,
          greaterThanOrEqualTo(28),
          reason:
              '12pt further in than the original 16 (rounded screen corner)',
        );
      },
    );

    testWidgets('foldable: a new empty conversation shows its default name', (
      t,
    ) async {
      await pumpHome(t, duoOuter, size: const Size(466, 678));
      final line = find.byKey(const ValueKey('chat-heading-line'));
      expect(
        find.descendant(of: line, matching: find.text('新建会话')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: line, matching: find.text('JARVIS')),
        findsNothing,
      );
    });

    testWidgets('other devices keep the app name and the small title', (
      t,
    ) async {
      await pumpHome(t, DuoLayout.none, seed: seedTitle);
      final line = find.byKey(const ValueKey('chat-heading-line'));
      expect(
        find.descendant(of: line, matching: find.text('JARVIS')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: line, matching: find.text('关于折叠屏的会话')),
        findsOneWidget,
      );
    });
  });

  group('Keyboard up', () {
    DuoRailAction a(String id) => DuoRailAction(
      id: id,
      icon: Icons.circle,
      symbol: 'circle',
      label: id,
      onPressed: () {},
    );
    List<String> ids(List<DuoRailAction> l) => [for (final x in l) x.id];

    test('everything fits: the bottom group moves up under the top group', () {
      final s = splitDuoRailForKeyboard(
        [a('t1'), a('t2')],
        [a('b1')],
        3 * 58,
        extent: 58,
      );
      expect(ids(s.top), ['t1', 't2', 'b1']);
      expect(s.bottom, isEmpty);
      expect(s.overflow, isEmpty);
    });

    test(
      'not everything fits: the bottom group goes into the overflow menu',
      () {
        final s = splitDuoRailForKeyboard(
          [a('t1'), a('t2')],
          [a('b1'), a('b2')],
          3 * 58,
          extent: 58,
        );
        expect(ids(s.top), ['t1', 't2']);
        expect(s.bottom, isEmpty);
        expect(ids(s.overflow), ['b1', 'b2']);
      },
    );

    test(
      'very little room: fewer top items, the rest overflow; none: nothing',
      () {
        final two = splitDuoRailForKeyboard(
          [a('t1'), a('t2')],
          [a('b1')],
          2 * 58,
          extent: 58,
        );
        expect(ids(two.top), ['t1']);
        expect(ids(two.overflow), ['t2', 'b1']);
        final none = splitDuoRailForKeyboard(
          [a('t1')],
          [a('b1')],
          30,
          extent: 58,
        );
        expect(none.top, isEmpty);
        expect(none.overflow, isEmpty);
      },
    );

    testWidgets(
      'on iOS the strip is one fixed view: the keyboard never resizes or moves it',
      (t) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(
          () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform_views,
            null,
          ),
        );
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          (call) async => null,
        );
        try {
          await pumpHome(t, duoLandscape);
          final plain = t.getRect(find.byKey(const Key('duo-rail')));
          await pumpHome(t, duoLandscape, keyboard: 300);
          // Same strip with the keyboard up; the native view animates the controls into its "..." menu itself.
          expect(t.getRect(find.byKey(const Key('duo-rail'))), plain);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });

  testWidgets('Unfolded: welcome cards line up with the composer frame', (
    t,
  ) async {
    await pumpHome(t, duoLandscape);
    final frame = t.getRect(find.byKey(const Key('composer-frame')));
    final first = t.getRect(find.byKey(const ValueKey('starter-0')));
    final second = t.getRect(find.byKey(const ValueKey('starter-1')));
    expect(first.left, closeTo(frame.left, 1));
    expect(second.right, closeTo(frame.right, 1));
    expect(t.takeException(), isNull);
  });

  group('Swipe a conversation left to delete', () {
    Future<JarvisController> pumpTwo(WidgetTester t, DuoLayout layout) async {
      late JarvisController controller;
      await pumpHome(
        t,
        layout,
        insets: duoLandscape.safe,
        seed: (c) {
          controller = c;
          c.current.title = '第一个会话';
          c.current.messages.add(ChatMessage('user', '你好'));
          c.newConversation();
          c.current.title = '第二个会话';
          c.current.messages.add(ChatMessage('user', '再见'));
        },
      );
      return controller;
    }

    testWidgets(
      'foldable: a left swipe deletes it; the undo notice sits in the conversation list',
      (t) async {
        final c = await pumpTwo(t, duoLandscape);
        final victim = c.conversations.firstWhere((x) => x.title == '第一个会话');
        expect(c.conversations, hasLength(2));
        await t.fling(
          find.byKey(ValueKey('conversation-surface-${victim.id}')),
          const Offset(-300, 0),
          1500,
        );
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        await t.pump(const Duration(milliseconds: 300));
        await t.pump(
          const Duration(milliseconds: 300),
        ); // let the notice's size animation settle
        expect(c.conversations.any((x) => x.id == victim.id), isFalse);
        expect(
          find.byType(SnackBar),
          findsNothing,
          reason: 'not over the chat',
        );
        final bar = t.getRect(find.byKey(const Key('sidebar-notice')));
        final list = t.getRect(find.byKey(const Key('conversation-list')));
        expect(
          bar.right,
          lessThanOrEqualTo(list.right + 12),
          reason: 'inside the sidebar column',
        );
        expect(
          bar.top,
          greaterThan(669 / 2),
          reason: 'at the bottom of the sidebar, not up in the chat',
        );
        expect(bar.bottom, lessThanOrEqualTo(669));
        expect(
          find.descendant(
            of: find.byKey(const Key('sidebar-notice')),
            matching: find.text('会话已删除'),
          ),
          findsOneWidget,
        );
        // Undo brings it back and clears the notice.
        await t.tap(find.text('撤销'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(c.conversations.any((x) => x.id == victim.id), isTrue);
        expect(find.byKey(const Key('sidebar-notice')), findsNothing);
        await t.pump(const Duration(seconds: 2));
      },
    );

    testWidgets('the notice disappears by itself after 5 seconds', (t) async {
      final c = await pumpTwo(t, duoLandscape);
      final victim = c.conversations.firstWhere((x) => x.title == '第一个会话');
      await t.fling(
        find.byKey(ValueKey('conversation-surface-${victim.id}')),
        const Offset(-300, 0),
        1500,
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('sidebar-notice')), findsOneWidget);
      await t.pump(const Duration(milliseconds: 3500)); // ~4.1s in: still there
      expect(find.byKey(const Key('sidebar-notice')), findsOneWidget);
      await t.pump(const Duration(milliseconds: 1500)); // ~5.6s in: gone
      await t.pump(const Duration(milliseconds: 300)); // after its fade-out
      expect(find.byKey(const Key('sidebar-notice')), findsNothing);
    });

    testWidgets(
      'a conversation that is busy springs back with the existing notice',
      (t) async {
        final c = await pumpTwo(t, duoLandscape);
        final busy = c.conversations.firstWhere((x) => x.title == '第一个会话');
        busy.tasks.add(
          MediaTask(id: 'job', kind: 'video', prompt: '测试', args: {}),
        );
        expect(c.canDeleteConversation(busy.id), isFalse);
        await t.pump();
        await t.fling(
          find.byKey(ValueKey('conversation-surface-${busy.id}')),
          const Offset(-300, 0),
          1500,
        );
        await t.pump();
        await t.pump(const Duration(milliseconds: 600));
        expect(c.conversations.any((x) => x.id == busy.id), isTrue);
        expect(
          find.descendant(
            of: find.byKey(const Key('sidebar-notice')),
            matching: find.textContaining('请先结束此会话'),
          ),
          findsOneWidget,
        );
        await t.pump(const Duration(seconds: 2));
      },
    );

    testWidgets('other platforms keep the menu only', (t) async {
      await pumpTwo(t, DuoLayout.none);
      expect(find.byType(Dismissible), findsNothing);
      await t.pump(const Duration(seconds: 2));
    });
  });

  testWidgets(
    'iOS: a snack bar keeps its width next to the 84pt vertical-bar inset',
    (t) async {
      // A floating SnackBar adds the system side inset on top of its margins; without compensation the notice was
      // squeezed to ~100pt and its text wrapped one character per line.
      await pumpHome(t, duoLandscape, platform: TargetPlatform.iOS);
      showNotice(
        t.element(find.byType(ChatPanel)),
        '会话已删除',
        compact: true,
        action: SnackBarAction(label: '撤销', onPressed: () {}),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 1000));
      final text = t.getRect(find.text('会话已删除'));
      expect(
        text.height,
        lessThan(30),
        reason: 'one line, not one character per line',
      );
      expect(text.width, greaterThanOrEqualTo(60));
      final frame = t.getRect(find.byKey(const Key('composer-frame')));
      expect(
        text.left,
        closeTo(frame.left + 12, 1),
        reason:
            'the notice (12pt inner padding) starts at the composer frame edge',
      );
      await t.pump(const Duration(seconds: 4));
    },
  );

  group('Welcome screen as on the web client (foldable)', () {
    test('time-of-day greeting, as on the web client', () {
      String at(int hour) => timeGreeting(DateTime(2026, 10, 27, hour));
      expect(at(0), '还没休息吗？');
      expect(at(4), '还没休息吗？');
      expect(at(5), '早上好');
      expect(at(11), '早上好');
      expect(at(12), '下午好');
      expect(at(17), '下午好');
      expect(at(18), '晚上好');
      expect(at(23), '晚上好');
    });

    test('descriptions are the web client\'s wording', () {
      final all = {
        for (final g in starterGroups)
          for (final s in g) s.title: s.description,
      };
      expect(all['拆解一个问题'], '抓住核心，找到下一步');
      expect(all['做一个小工具'], '编写处理重复工作的工具代码');
      expect(all['准备一次沟通'], '理清目的，组织好要说的话');
      expect(all.length, 17);
    });

    test('every starter has a description and the picks stay random', () {
      for (final group in starterGroups) {
        for (final starter in group) {
          expect(starter.description, isNotEmpty, reason: starter.title);
        }
      }
      // One card from each of the four groups, different between app sessions (not hard-coded).
      final seen = <String>{};
      for (var i = 0; i < 60; i++) {
        final pick = SessionStarters().available((_) => true);
        expect(pick, hasLength(4));
        for (var g = 0; g < 4; g++) {
          expect(starterGroups[g].map((s) => s.title), contains(pick[g].title));
        }
        seen.add(pick.map((s) => s.title).join('|'));
      }
      expect(seen.length, greaterThan(1));
    });

    testWidgets(
      'greeting, subtitle and the session\'s four random cards, two lines each',
      (t) async {
        final before = timeGreeting(DateTime.now());
        final c = await pumpHome(t, duoLandscape);
        // Tolerate an hour boundary passing while the test runs.
        expect(
          {
            before,
            timeGreeting(DateTime.now()),
          }.where((g) => find.text(g).evaluate().isNotEmpty),
          hasLength(1),
        );
        expect(find.text('有什么想聊的？输入问题，或点击麦克风直接说话。'), findsOneWidget);
        expect(find.text('想聊点什么？'), findsNothing);
        expect(c.starters, hasLength(4));
        for (final starter in c.starters) {
          expect(
            find.text(starter.title),
            findsOneWidget,
            reason: starter.title,
          );
          expect(
            find.text(starter.description!),
            findsOneWidget,
            reason: starter.description,
          );
        }
        // Two lines per card: the description sits under the title.
        final first = c.starters.first;
        final title = t.getRect(find.text(first.title));
        final description = t.getRect(find.text(first.description!));
        expect(description.top, greaterThan(title.bottom - 1));
        // 2x2 grid.
        final card0 = t.getRect(find.byKey(const ValueKey('starter-0')));
        final card2 = t.getRect(find.byKey(const ValueKey('starter-2')));
        expect(card2.top, greaterThan(card0.bottom));
        expect(card2.left, closeTo(card0.left, 1));
      },
    );

    testWidgets('outer display: every description is a single 12pt line', (
      t,
    ) async {
      final c = await pumpHome(t, duoOuter, size: const Size(466, 678));
      for (final starter in c.starters) {
        final paragraph = t.renderObject<RenderParagraph>(
          find.text(starter.description!),
        );
        // 12pt on a ~164pt card: never cut with an ellipsis (the tile takes a second line when one is not enough).
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: starter.description,
        );
        expect(
          paragraph.size.height,
          lessThan(40),
          reason: starter.description,
        );
      }
      // Titles line up across a row.
      expect(
        t.getRect(find.text(c.starters[0].title)).top,
        closeTo(t.getRect(find.text(c.starters[1].title)).top, 1),
      );
      // The cards still sit in the composer's column on the narrow screen.
      final frame = t.getRect(find.byKey(const Key('composer-frame')));
      final first = t.getRect(find.byKey(const ValueKey('starter-0')));
      final second = t.getRect(find.byKey(const ValueKey('starter-1')));
      expect(first.left, closeTo(frame.left, 1));
      expect(second.right, closeTo(frame.right, 1));
    });

    testWidgets('tapping a card puts its prompt in the composer', (t) async {
      final c = await pumpHome(t, duoLandscape);
      await t.tap(find.byKey(const ValueKey('starter-1')));
      await t.pump();
      expect(c.current.draft, c.starters[1].prompt);
      await t.pump(const Duration(seconds: 2)); // debounced save
    });

    testWidgets('other devices keep the original welcome screen', (t) async {
      await pumpHome(t, DuoLayout.none, insets: duoLandscape.safe);
      expect(find.text('想聊点什么？'), findsOneWidget);
      expect(find.text('写下想法，或直接开口。'), findsOneWidget);
      expect(find.text('保留你的意思，表达更清楚'), findsNothing);
    });
  });

  testWidgets(
    'The app name is JARVIS (sidebar brand and chat heading), never "Jarvis"',
    (t) async {
      await pumpHome(t, duoLandscape);
      expect(
        find.text('JARVIS'),
        findsOneWidget,
        reason: 'sidebar brand; the foldable heading shows the conversation',
      );
      expect(find.text('Jarvis'), findsNothing);
      final brand = t.getRect(find.text('JARVIS'));
      expect(brand.right, lessThan(251), reason: 'fits in the sidebar');
      expect(
        t.widget<Text>(find.text('JARVIS')).style?.fontSize,
        18,
        reason: 'one size smaller on a foldable',
      );
      await t.pumpWidget(const SizedBox());
      await pumpHome(t, DuoLayout.none, insets: duoLandscape.safe);
      expect(
        find.text('JARVIS'),
        findsNWidgets(2),
        reason: 'sidebar brand + chat heading',
      );
      expect(
        t.widget<Text>(find.text('JARVIS').first).style?.fontSize,
        20,
        reason: 'other devices keep 20',
      );
      expect(find.text('Jarvis'), findsNothing);
      await t.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'foldable: the send button is the same size as the mic button beside it',
    (t) async {
      final c = await pumpHome(
        t,
        duoLandscape,
        seed: (x) => x.current.draft = '你好',
      );
      await t.pump();
      Finder button(String tooltip) => find
          .ancestor(
            of: find.byTooltip(tooltip),
            matching: find.byType(IconButton),
          )
          .first;
      Size? fixed(String tooltip) =>
          t.widget<IconButton>(button(tooltip)).style?.fixedSize?.resolve({});
      expect(find.byTooltip('发送'), findsOneWidget);
      expect(fixed('发送'), const Size(36, 36));
      expect(fixed('语音对话'), const Size(36, 36));
      // Same visual and hit sizes.
      expect(t.getSize(button('发送')), t.getSize(button('语音对话')));
      expect(c.current.draft, '你好');
      await t.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'narrow (outer display) cards: title and description each fit on one line',
    (t) async {
      for (final group in starterGroups) {
        for (final starter in group) {
          await t.pumpWidget(
            MaterialApp(
              home: Center(
                child: SizedBox(
                  width: 164, // outer display: (466 - 84 strip - 2*22 gap - 10) / 2
                  height: 76,
                  child: WebStarterCard(
                    starter: starter,
                    compact: true,
                    onPressed: () {},
                  ),
                ),
              ),
            ),
          );
          final title = t.renderObject<RenderParagraph>(
            find.text(starter.title),
          );
          final description = t.renderObject<RenderParagraph>(
            find.text(starter.description!),
          );
          expect(
            title.size.height,
            lessThan(26),
            reason: '${starter.title}: one line',
          );
          expect(
            description.size.height,
            lessThan(22),
            reason: '${starter.title}: ${starter.description} on one line',
          );
          expect(
            t.takeException(),
            isNull,
            reason: 'no overflow in ${starter.title}',
          );
        }
      }
    },
  );

  testWidgets(
    'outer display of a foldable: the conversation drawer is 21% wider',
    (t) async {
      await pumpHome(t, duoOuter, size: const Size(466, 678));
      await t.tap(find.byKey(const Key('duo-rail-sidebar')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      // Default: 65% of the usable width (466 - 84).
      final base = (466 - 84) * .65;
      expect(t.getSize(find.byType(Drawer)).width, closeTo(base * 1.21, 1));
      await t.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('other devices keep the default drawer width', (t) async {
    await pumpHome(
      t,
      DuoLayout.none,
      size: const Size(466, 678),
      insets: duoOuter.safe,
    );
    await t.tap(find.byIcon(Icons.menu));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(t.getSize(find.byType(Drawer)).width, closeTo((466 - 84) * .65, 1));
    await t.pump(const Duration(seconds: 2));
  });

  group('Rename dialog', () {
    Future<void> openRename(WidgetTester t, Finder open) async {
      await t.tap(open);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.byTooltip('会话操作').first);
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text('重命名'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
    }

    testWidgets(
      'outer display of a foldable: uses the screen, bigger type and buttons',
      (t) async {
        await pumpHome(t, duoOuter, size: const Size(466, 678));
        await openRename(t, find.byKey(const Key('duo-rail-sidebar')));
        final dialog = t.getRect(
          find
              .descendant(
                of: find.byKey(const Key('rename-dialog')),
                matching: find.byType(Material),
              )
              .first,
        );
        // Usable width = 466 - 84 (vertical-bar strip); the dialog keeps the 22pt gap on both sides.
        expect(dialog.left, closeTo(DuoLayout.edgeGap, 1));
        expect(dialog.width, closeTo(466 - 84 - 2 * DuoLayout.edgeGap, 1));
        expect(
          t
              .widget<TextField>(find.byKey(const Key('rename-field')))
              .style
              ?.fontSize,
          18,
        );
        expect(
          t.getSize(find.widgetWithText(FilledButton, '保存')).height,
          greaterThanOrEqualTo(52),
        );
        expect(
          t.getSize(find.widgetWithText(TextButton, '取消')).height,
          greaterThanOrEqualTo(52),
        );
        await t.tap(find.widgetWithText(TextButton, '取消'));
        await t.pump(const Duration(seconds: 1));
      },
    );

    testWidgets('other devices keep the default dialog', (t) async {
      await pumpHome(
        t,
        DuoLayout.none,
        size: const Size(466, 678),
        insets: duoOuter.safe,
      );
      await openRename(t, find.byIcon(Icons.menu));
      final dialog = t.getRect(
        find
            .descendant(
              of: find.byKey(const Key('rename-dialog')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(
        dialog.width,
        closeTo(280, 1),
        reason: 'default 40pt inset on each side',
      );
      expect(
        t
            .widget<TextField>(find.byKey(const Key('rename-field')))
            .style
            ?.fontSize,
        isNull,
      );
      await t.tap(find.widgetWithText(TextButton, '取消'));
      await t.pump(const Duration(seconds: 1));
    });
  });

  testWidgets('the home rail steps aside while the call page is open', (
    t,
  ) async {
    final c = await pumpHome(t, duoLandscape);
    expect(find.byKey(const Key('duo-rail-sidebar')), findsOneWidget);
    c.voice.owner = c.current;
    c.voice.expand();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('duo-rail-sidebar')), findsNothing);
    c.voice.minimize();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('duo-rail-sidebar')), findsOneWidget);
    await t.pump(const Duration(seconds: 2)); // debounced save
  });

  testWidgets(
    'settings with the keyboard up: no fade strip or extra inset on the keyboard',
    (t) async {
      final c = await pumpHome(t, duoLandscape, keyboard: 300);
      unawaited(
        t
            .state<NavigatorState>(find.byType(Navigator).first)
            .push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsPage(controller: c),
              ),
            ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('settings-scroll')), findsOneWidget);
      expect(find.byKey(const Key('soft-bottom-edge')), findsNothing);
      expect(
        t.getRect(find.byKey(const Key('settings-scroll'))).bottom,
        lessThanOrEqualTo(669 - 300),
      );
    },
  );

  testWidgets('a tap reported by the native rail reaches Dart', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    final created = <Map<Object?, Object?>>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        if (call.method == 'create') {
          created.add(call.arguments as Map<Object?, Object?>);
        }
        return null;
      },
    );
    try {
      await pumpHome(t, duoLandscape);
      expect(created, hasLength(1));
      final id = created.single['id'];
      await t.binding.defaultBinaryMessenger.handlePlatformMessage(
        'ai.jarvis.app/duo-rail/$id',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('tap', 'settings'),
        ),
        (_) {},
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(SettingsPage), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'tapping the native rail keeps the keyboard up (its menu would vanish)',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async => null,
      );
      try {
        await pumpHome(t, duoLandscape);
        await t.tap(find.byType(TextField).first);
        await t.pump();
        bool editing() =>
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<EditableText>() !=
            null;
        expect(editing(), isTrue);
        await t.tapAt(t.getCenter(find.byKey(const Key('duo-rail'))));
        await t.pump();
        expect(
          editing(),
          isTrue,
          reason: 'a tap on the strip is not "outside"',
        );
        // Elsewhere it still hides the keyboard.
        await t.tapAt(const Offset(500, 100));
        await t.pump();
        expect(editing(), isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test('the bottom controls come back down with the keyboard, at its pace', () {
    // Rising: they leave their resting place as the keyboard climbs (never before it, never after it has stopped).
    double lift(double k) => DuoRail.liftFor(k, 678);
    expect(lift(0), 1);
    var previous = 1.0;
    for (final k in [20.0, 60.0, 120.0, 200.0, 300.0]) {
      final now = lift(k);
      expect(now, lessThanOrEqualTo(previous));
      previous = now;
    }
    expect(previous, 0, reason: 'stacked once the keyboard is up');
    // Falling: back to rest in proportion to the keyboard's height, reaching it as the keyboard does.
    expect(lift(150), closeTo(.5, .01));
    expect(lift(75), closeTo(.75, .01));
    expect(lift(0), 1);
    // The next round learns how high the keyboard stood.
    expect(lift(150), closeTo(1 - 150 / 300, .01));
    expect(lift(0), 1);
  });

  test('the first fall carries on from where the guessed rise left them', () {
    // A window height never seen before: the rise follows a guess (36% of the height = 360), the keyboard stops lower.
    double lift(double k) => DuoRail.liftFor(k, 1000);
    expect(lift(0), 1);
    lift(100);
    final atPeak = lift(200);
    expect(atPeak, closeTo(1 - 200 / 360, .001));
    // The first frame down does not jump to the "fully lifted" end.
    final firstFall = lift(195);
    expect(firstFall, closeTo(atPeak, .03));
    expect(firstFall, greaterThanOrEqualTo(atPeak));
    // Then it reaches rest exactly as the keyboard does, never going backwards.
    var previous = firstFall;
    for (final k in [150.0, 100.0, 50.0, 10.0]) {
      final now = lift(k);
      expect(now, greaterThanOrEqualTo(previous));
      expect(now, lessThan(1));
      previous = now;
    }
    expect(lift(0), 1);
    // The second round knows the real travel (200) and uses it going up as well.
    expect(lift(100), closeTo(.5, .001));
    expect(lift(0), 1);
  });
}
