import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/audio_waveform.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart' show CoreAvatar;
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/voice_mode_selector.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/ui/login_art.dart' show ReactorMode;
import 'package:jarvis_android/voice/audio_levels.dart';

import 'support.dart';
import 'voice_layout_test.dart' show LayoutApi;
import 'voice_support.dart';

DuoLayout layoutOf({
  String edge = 'none',
  required double width,
  required double height,
  EdgeInsets safe = EdgeInsets.zero,
  required List<Map<String, Object>> regions,
}) => DuoLayout.fromMap({
  'edge': edge,
  'width': width,
  'height': height,
  'safe': {
    'left': safe.left,
    'top': safe.top,
    'right': safe.right,
    'bottom': safe.bottom,
  },
  'regions': regions,
});

Map<String, Object> division({
  required bool active,
  required double x,
  required double y,
  required double w,
  required double h,
}) => {'kind': 'division', 'active': active, 'x': x, 'y': y, 'w': w, 'h': h};

// Inner display, landscape, half-folded: a vertical crease at x=455.5.
final landscapeHalfFolded = layoutOf(
  edge: 'right',
  width: 951,
  height: 669,
  safe: const EdgeInsets.only(right: 84, bottom: 34),
  regions: [
    division(active: true, x: 455.5, y: 0, w: 40, h: 669),
    {
      'kind': 'occlusion',
      'active': true,
      'x': 867.0,
      'y': 0.0,
      'w': 84.0,
      'h': 124.0,
    },
  ],
);

// Inner display, portrait, half-folded: a horizontal crease at y=455.5, no vertical strip.
DuoLayout portrait({required bool halfFolded}) => layoutOf(
  width: 669,
  height: 951,
  safe: const EdgeInsets.only(top: 54, bottom: 34),
  regions: [division(active: halfFolded, x: 0, y: 455.5, w: 669, h: 40)],
);

// Outer display: vertical strip, no fold region.
final outer = layoutOf(
  edge: 'right',
  width: 466,
  height: 678,
  safe: const EdgeInsets.only(right: 84, bottom: 34),
  regions: [
    {
      'kind': 'occlusion',
      'active': true,
      'x': 382.0,
      'y': 0.0,
      'w': 84.0,
      'h': 174.0,
    },
  ],
);

Future<JarvisController> pumpVoice(
  WidgetTester t,
  DuoLayout layout, {
  Size? size,
  bool works = false,
  bool recover = false,
  double textScale = 1,
  ApiFactory? api,
}) async {
  final s = size ?? (layout.size.isEmpty ? const Size(400, 800) : layout.size);
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = s;
  t.view.padding = FakeViewPadding(
    top: layout.safe.top,
    right: layout.safe.right,
    bottom: layout.safe.bottom,
  );
  t.view.viewPadding = t.view.padding;
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetPadding);
  addTearDown(t.view.resetViewPadding);
  final c = JarvisController(
    api == null ? FakeApi() : api(),
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
  if (recover) c.voice.error = '麦克风暂时不可用';
  await t.pumpWidget(
    DuoLayoutScope(
      layout: ValueNotifier(layout),
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: VoicePage(controller: c),
      ),
    ),
  );
  await t.pump();
  return c;
}

typedef ApiFactory = FakeApi Function();

void main() {
  group('layout geometry', () {
    test(
      'horizontalFold is the active wide division; verticalFold ignores it',
      () {
        final folded = portrait(halfFolded: true);
        expect(folded.horizontalFold, const Rect.fromLTWH(0, 455.5, 669, 40));
        expect(folded.verticalFold, isNull);
        expect(portrait(halfFolded: false).horizontalFold, isNull);
        expect(DuoLayout.none.horizontalFold, isNull);
        expect(landscapeHalfFolded.horizontalFold, isNull);
        expect(landscapeHalfFolded.verticalFold, isNotNull);
      },
    );

    test('foldPane is right of the vertical fold and inside the strip', () {
      final pane = landscapeHalfFolded.foldPane!;
      expect(pane.left, 495.5);
      expect(pane.right, 951 - 84);
      expect(DuoLayout.none.foldPane, isNull);
      expect(portrait(halfFolded: true).foldPane, isNull);
    });

    test(
      'dialogInsets stays on one side of the crease and is unchanged flat',
      () {
        const base = EdgeInsets.symmetric(horizontal: 40, vertical: 24);
        expect(DuoLayout.none.dialogInsets(), base);
        final inset = landscapeHalfFolded.dialogInsets();
        expect(inset.left, 495.5 + 40);
        expect(inset.right, 84 + 40);
        expect(
          portrait(halfFolded: true).dialogInsets().top,
          455.5 + 40 + 24,
          reason: 'below a horizontal crease',
        );
      },
    );
  });

  group('push-to-talk button semantics', () {
    testWidgets('one node in push-to-talk mode, no duplicated child text', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      final c = await pumpVoice(t, DuoLayout.none, size: const Size(400, 800));
      c.voice.ready = true;
      await t.pump();
      final node = find.semantics.byLabel('按住说话').evaluate().single;
      final data = node.getSemanticsData();
      expect(data.label, '按住说话');
      expect(node.childrenCount, 0, reason: 'the visible text is excluded');
      expect(
        find.semantics.byLabel('按住说话'),
        findsOneWidget,
        reason: 'announced once',
      );
      semantics.dispose();
    });

    testWidgets('in VAD mode the label says what a tap does', (t) async {
      final semantics = t.ensureSemantics();
      final c = await pumpVoice(t, DuoLayout.none, size: const Size(400, 800));
      c.settings.voiceMode = 'vad';
      c.voice.ready = true;
      c.voice.toggleMute();
      c.voice.toggleMute();
      await t.pump();
      SemanticsNode talk(String label) =>
          find.semantics.byLabel(label).evaluate().single;
      var data = talk('静音').getSemanticsData();
      expect(data.value, '正在聆听');
      expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
      expect(c.voice.muted, isFalse);
      t.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          type: ui.SemanticsAction.tap,
          viewId: t.view.viewId,
          nodeId: talk('静音').id,
        ),
      );
      await t.pump();
      expect(c.voice.muted, isTrue);
      data = talk('取消静音').getSemanticsData();
      expect(data.value, '已静音');
      await t.pump(const Duration(seconds: 3));
      semantics.dispose();
    });
  });

  group('waveform', () {
    /// Counts the painter's repaint notifications (what drives a repaint).
    int Function() countRepaints(WidgetTester t) {
      final painter = t
          .widget<CustomPaint>(find.byKey(const Key('voice-waveform')))
          .painter!;
      var n = 0;
      painter.addListener(() => n++);
      return () => n;
    }

    testWidgets('a silent meter does not repaint every frame', (t) async {
      final levels = ValueNotifier(const AudioLevels());
      await t.pumpWidget(
        MaterialApp(
          home: SizedBox(height: 40, child: AudioWaveform(levels: levels)),
        ),
      );
      final repaints = countRepaints(t);
      await t.pump(const Duration(milliseconds: 50));
      final before = repaints();
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 34));
      }
      expect(repaints(), before, reason: 'flat line, nothing to redraw');
      // Sound brings the animation back.
      levels.value = const AudioLevels(input: .3);
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 34));
      }
      expect(repaints(), greaterThan(before));
      // ...and it settles to a stop again once the level has decayed to zero.
      levels.value = const AudioLevels();
      for (var i = 0; i < 80; i++) {
        await t.pump(const Duration(milliseconds: 34));
      }
      final settled = repaints();
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 34));
      }
      expect(repaints(), settled);
      await t.pumpWidget(const SizedBox());
    });

    for (final dark in [false, true]) {
      testWidgets('listening colour on the ${dark ? 'dark' : 'light'} theme', (
        t,
      ) async {
        final levels = ValueNotifier(const AudioLevels(input: .5));
        await t.pumpWidget(
          MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: SizedBox(height: 40, child: AudioWaveform(levels: levels)),
            ),
          ),
        );
        await t.pump();
        final expected = dark ? 0x8fdceb : 0x137589;
        expect(
          t.renderObject(find.byKey(const Key('voice-waveform'))),
          paints..something(
            (name, args) =>
                name == #drawLine &&
                ((args[2] as Paint).color.toARGB32() & 0xffffff) == expected,
          ),
        );
      });
    }
  });

  group('settings widgets', () {
    Widget host(Widget child, {double scale = 1, ThemeData? theme}) =>
        MaterialApp(
          theme: theme,
          builder: (context, c) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: c!,
          ),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        );

    testWidgets('picker row keeps its value visible at the largest text size', (
      t,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 800);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      await t.pumpWidget(
        host(
          PickerRow<int>(
            label: '回答前等待时长',
            value: 3000,
            options: const [(3000, '3 秒')],
            onSelected: (_) {},
          ),
          scale: 2.4,
        ),
      );
      final label = t.getRect(find.text('回答前等待时长'));
      final value = t.getRect(find.text('3 秒'));
      expect(value.top, greaterThanOrEqualTo(label.bottom - 1));
      final text = t.widget<Text>(find.text('3 秒'));
      expect(text.maxLines, greaterThan(1));
      expect(t.takeException(), isNull);
    });

    testWidgets('picker row stays one line at the normal text size', (t) async {
      await t.pumpWidget(
        host(
          PickerRow<int>(
            label: '回答前等待时长',
            value: 3000,
            options: const [(3000, '3 秒')],
            onSelected: (_) {},
          ),
        ),
      );
      final label = t.getRect(find.text('回答前等待时长'));
      final value = t.getRect(find.text('3 秒'));
      expect(value.center.dy, closeTo(label.center.dy, 2));
      // The value and its chevron sit flush with the row's right edge, not wherever the label's share ends.
      final row = t.getRect(find.byType(PickerRow<int>));
      final chevron = t.getRect(find.byIcon(Icons.unfold_more_rounded));
      expect(chevron.right, closeTo(row.right - 16, 1));
    });

    testWidgets('a field row names its text field for assistive technology', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      final field = TextEditingController();
      addTearDown(field.dispose);
      await t.pumpWidget(
        host(FieldRow(label: '助手指令', controller: field, onChanged: (_) {})),
      );
      final data = t.getSemantics(find.byType(TextField)).getSemanticsData();
      expect(data.label, contains('助手指令'));
      expect(data.flagsCollection.isTextField, isTrue);
      expect(
        find.semantics.byLabel('助手指令'),
        findsOneWidget,
        reason: 'the visible caption is not announced a second time',
      );
      semantics.dispose();
    });

    testWidgets('a section title is a heading', (t) async {
      final semantics = t.ensureSemantics();
      await t.pumpWidget(
        host(
          const SettingsSection(title: '外观', children: [SizedBox(height: 8)]),
        ),
      );
      final data = t.getSemantics(find.text('外观')).getSemanticsData();
      expect(data.flagsCollection.isHeader, isTrue);
      semantics.dispose();
    });

    testWidgets('the light card is lifted off the page and outlined', (
      t,
    ) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.setTheme('light');
      await t.pumpWidget(JarvisApp(controller: c));
      await t.pump();
      await c.login('user', 'test');
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      final nav = t
          .widget<MaterialApp>(find.byType(MaterialApp))
          .navigatorKey!
          .currentState!;
      nav.push(
        MaterialPageRoute<void>(builder: (_) => SettingsPage(controller: c)),
      );
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      final context = t.element(find.byType(SettingsPage));
      final page = Theme.of(context).scaffoldBackgroundColor;
      expect(Theme.of(context).brightness, Brightness.light);
      final card = t.widget<Material>(
        find
            .descendant(
              of: find.byType(SettingsGroup),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(card.color, isNot(page));
      expect(card.color, const Color(0xffffffff));
      final side = (card.shape as RoundedRectangleBorder).side;
      expect(side.color.a, 1, reason: 'a hairline you can see on the page');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('increase contrast gives the card a solid outline', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(highContrast: true),
            child: child!,
          ),
          home: const Scaffold(
            body: SettingsGroup(children: [SizedBox(height: 40)]),
          ),
        ),
      );
      final card = t.widget<Material>(
        find
            .descendant(
              of: find.byType(SettingsGroup),
              matching: find.byType(Material),
            )
            .first,
      );
      final scheme = ThemeData.light().colorScheme;
      expect((card.shape as RoundedRectangleBorder).side.color, scheme.outline);
    });

    testWidgets('dark theme keeps the soft card', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: SettingsGroup(children: [SizedBox(height: 40)]),
          ),
        ),
      );
      final scheme = ThemeData.dark().colorScheme;
      final card = t.widget<Material>(
        find
            .descendant(
              of: find.byType(SettingsGroup),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(
        card.color,
        Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, .35),
      );
    });
  });

  group('settings page actions', () {
    Future<JarvisController> open(
      WidgetTester t, {
      DuoLayout layout = DuoLayout.none,
      Size size = const Size(466, 900),
    }) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        DuoLayoutScope(
          layout: ValueNotifier(layout),
          child: MaterialApp(home: SettingsPage(controller: c)),
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      return c;
    }

    Future<void> reveal(WidgetTester t, String text) async {
      await t.scrollUntilVisible(
        find.text(text),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('settings-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.drag(
        find.byKey(const Key('settings-scroll')),
        const Offset(0, -80),
      );
      await t.pump();
    }

    testWidgets('copying the diagnostics says so', (t) async {
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final c = await open(t);
      await reveal(t, '复制诊断信息');
      await t.tap(find.text('复制诊断信息'));
      await t.pump();
      await t.pump();
      expect(copied, isNotNull);
      expect(find.text('诊断信息已复制'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('signing out asks first, and cancelling keeps the session', (
      t,
    ) async {
      final api = FakeApi();
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await c.login('user', 'test');
      await t.pumpWidget(MaterialApp(home: SettingsPage(controller: c)));
      await t.pump(const Duration(milliseconds: 400));
      await reveal(t, '退出登录');
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      expect(find.text('退出登录？'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(find.text('退出登录？'), findsNothing);
      expect(c.authenticated, isTrue);
      expect(api.cookie, isNotNull);
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, '退出登录'));
      await t.pump();
      await t.pump();
      expect(c.authenticated, isFalse);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('the delete button is the error colour', (t) async {
      final c = await open(t);
      await reveal(t, '删除全部会话');
      await t.tap(find.text('删除全部会话'));
      await t.pumpAndSettle();
      final button = t.widget<FilledButton>(
        find.widgetWithText(FilledButton, '删除全部'),
      );
      final scheme = Theme.of(t.element(find.byType(AlertDialog))).colorScheme;
      expect(button.style?.backgroundColor?.resolve({}), scheme.error);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('half-folded in landscape the dialog stays right of the fold', (
      t,
    ) async {
      final c = await open(
        t,
        layout: landscapeHalfFolded,
        size: const Size(951, 669),
      );
      await reveal(t, '删除全部会话');
      await t.tap(find.text('删除全部会话'));
      await t.pumpAndSettle();
      final dialog = t.getRect(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(dialog.left, greaterThanOrEqualTo(495.5));
      expect(dialog.right, lessThanOrEqualTo(951 - 84));
      for (final label in ['取消', '删除全部']) {
        expect(
          t.getRect(find.text(label)).left,
          greaterThanOrEqualTo(495.5),
          reason: label,
        );
      }
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('voice page', () {
    testWidgets('mode selector hit areas are 44 points tall', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceModeSelector(value: 'ptt', onChanged: (_) {}),
          ),
        ),
      );
      for (final id in ['ptt', 'vad']) {
        final size = t.getSize(find.byKey(ValueKey('voice-mode-$id')));
        expect(size.height, greaterThanOrEqualTo(44), reason: id);
      }
    });

    testWidgets('the avatar is always a named interrupt button', (t) async {
      final semantics = t.ensureSemantics();
      var taps = 0;
      for (final compact in [false, true]) {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(20),
                child: VoiceIdentityStage(
                  compact: compact,
                  windowHeight: 800,
                  identity: 'x',
                  status: '正在回答',
                  hint: '点击头像打断',
                  mode: ReactorMode.speaking,
                  onTap: () => taps++,
                  transcript: const SizedBox(),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        final node = find.semantics.byLabel('打断回复');
        final semNode = node.evaluate().single;
        expect(node, findsOneWidget, reason: 'compact: $compact');
        expect(semNode.getSemanticsData().flagsCollection.isButton, isTrue);
        t.binding.performSemanticsAction(
          ui.SemanticsActionEvent(
            type: ui.SemanticsAction.tap,
            viewId: t.view.viewId,
            nodeId: semNode.id,
          ),
        );
      }
      expect(taps, 2);
      semantics.dispose();
    });

    testWidgets('rail: hang up sits alone at the bottom, away from collapse', (
      t,
    ) async {
      await pumpVoice(t, outer, works: true);
      final strip = t.getRect(find.byKey(const Key('duo-rail')));
      final hangup = t.getRect(find.byKey(const Key('duo-rail-hangup')));
      final collapse = t.getRect(find.byKey(const Key('duo-rail-collapse')));
      final works = t.getRect(find.byKey(const Key('duo-rail-works')));
      expect(hangup.bottom, closeTo(strip.bottom, 8));
      expect(collapse.top, closeTo(strip.top, 8));
      expect(
        hangup.top - works.bottom,
        greaterThan(100),
        reason: 'no other control within a thumb slip of hang up',
      );
      expect(hangup.top - collapse.bottom, greaterThan(100));
    });

    testWidgets('rail: recover moves to the top group too', (t) async {
      await pumpVoice(t, outer, recover: true);
      expect(find.byKey(const Key('duo-rail-recover')), findsOneWidget);
      expect(
        find.widgetWithText(TextButton, '恢复语音'),
        findsNothing,
        reason: 'the page has no second copy while the strip carries it',
      );
    });

    testWidgets('without a strip the page keeps recover and works rows', (
      t,
    ) async {
      await pumpVoice(
        t,
        portrait(halfFolded: false),
        works: true,
        recover: true,
      );
      expect(find.widgetWithText(TextButton, '恢复语音'), findsOneWidget);
      expect(find.textContaining('生成作品 ·'), findsOneWidget);
    });

    testWidgets(
      'split controls: the mode selector is capped like the stacked one',
      (t) async {
        await pumpVoice(t, landscapeHalfFolded);
        expect(
          find.byKey(const Key('voice-controls-fold-split')),
          findsOneWidget,
        );
        expect(
          t.getSize(find.byType(VoiceModeSelector)).width,
          lessThanOrEqualTo(360),
        );
      },
    );

    group('portrait half-fold', () {
      Rect rect(WidgetTester t, Finder f) => t.getRect(f);

      testWidgets('controls, header and picker sit below the crease', (
        t,
      ) async {
        final layout = portrait(halfFolded: true);
        await pumpVoice(t, layout);
        final band = layout.horizontalFold!;
        for (final (name, finder) in [
          ('talk', find.byKey(const Key('voice-talk'))),
          ('mode', find.byType(VoiceModeSelector)),
          ('voice name', find.byKey(const Key('voice-name'))),
          ('hang up', find.byTooltip('结束语音通话')),
          ('collapse', find.byTooltip('收起通话界面')),
        ]) {
          expect(
            rect(t, finder).top,
            greaterThanOrEqualTo(band.bottom - .5),
            reason: name,
          );
        }
        // The avatar (tap to interrupt) is wholly above it.
        expect(
          rect(t, find.byType(VoiceIdentityStage)).bottom,
          lessThanOrEqualTo(band.top + .5),
        );
        expect(
          rect(t, find.byType(CoreAvatar)).bottom,
          lessThanOrEqualTo(band.top + .5),
        );
        expect(t.takeException(), isNull);
      });

      testWidgets('flat (inactive crease) the header stays on top', (t) async {
        await pumpVoice(t, portrait(halfFolded: false));
        expect(
          rect(t, find.byKey(const Key('voice-name'))).top,
          lessThan(455.5),
        );
        expect(rect(t, find.byTooltip('结束语音通话')).top, lessThan(455.5));
      });

      testWidgets('no fold reported: layout is the ordinary one', (t) async {
        await pumpVoice(t, DuoLayout.none, size: const Size(669, 951));
        expect(rect(t, find.byKey(const Key('voice-name'))).top, lessThan(100));
        expect(find.byKey(const Key('voice-fold-controls')), findsNothing);
      });

      testWidgets('large text scrolls the lower group instead of overflowing', (
        t,
      ) async {
        final layout = portrait(halfFolded: true);
        await pumpVoice(t, layout, works: true, recover: true, textScale: 2.4);
        expect(t.takeException(), isNull);
        expect(
          rect(t, find.byKey(const Key('voice-fold-controls'))).top,
          greaterThanOrEqualTo(layout.horizontalFold!.bottom - .5),
        );
      });

      testWidgets('the voice picker stays in the half below the crease', (
        t,
      ) async {
        final layout = portrait(halfFolded: true);
        final c = await pumpVoice(t, layout, api: LayoutApi.new);
        await c.login('user', 'test');
        await t.pump();
        await t.tap(find.byKey(const Key('voice-name')));
        await t.pumpAndSettle();
        expect(find.text('选择音色'), findsOneWidget);
        expect(
          t.getRect(find.byType(BottomSheet)).top,
          greaterThanOrEqualTo(layout.horizontalFold!.bottom - .5),
        );
        Navigator.of(t.element(find.text('选择音色'))).pop();
        await t.pumpAndSettle();
      });
    });

    testWidgets('the voice picker sheet stays right of a vertical fold', (
      t,
    ) async {
      final c = await pumpVoice(t, landscapeHalfFolded, api: LayoutApi.new);
      await c.login('user', 'test');
      await t.pump();
      await t.tap(find.byKey(const Key('voice-name')));
      await t.pumpAndSettle();
      expect(find.text('选择音色'), findsOneWidget);
      final sheet = t.getRect(find.text('选择音色'));
      expect(sheet.left, greaterThanOrEqualTo(495.5));
      final material = t.getRect(
        find
            .ancestor(of: find.text('选择音色'), matching: find.byType(Material))
            .first,
      );
      expect(material.left, greaterThanOrEqualTo(495.5));
      expect(material.right, lessThanOrEqualTo(951 - 84 + .5));
      Navigator.of(t.element(find.text('选择音色'))).pop();
      await t.pumpAndSettle();
    });

    testWidgets('the voice picker is the ordinary sheet when flat', (t) async {
      final c = await pumpVoice(t, DuoLayout.none, api: LayoutApi.new);
      await c.login('user', 'test');
      await t.pump();
      await t.tap(find.byKey(const Key('voice-name')));
      await t.pumpAndSettle();
      expect(find.text('选择音色'), findsOneWidget);
      final sheet = t.getRect(find.byType(BottomSheet));
      expect(sheet.width, 400);
      Navigator.of(t.element(find.text('选择音色'))).pop();
      await t.pumpAndSettle();
    });
  });
}
