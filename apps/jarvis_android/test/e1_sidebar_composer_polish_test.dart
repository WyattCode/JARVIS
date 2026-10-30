import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/motion.dart';
import 'package:jarvis_android/ui/settings_page.dart';

import 'b_chat_ui_test.dart' show openDrawer, pumpPhone;
import 'duo_rail_test.dart' show duoOuter, pumpHome;
import 'support.dart';

/// The app's own light and dark themes (main.dart), read off its MaterialApp.
Future<({ThemeData light, ThemeData dark})> appThemes(WidgetTester t) async {
  final c = JarvisController(FakeApi(), MemoryVault());
  await c.initialize();
  await t.pumpWidget(JarvisApp(controller: c));
  final app = t.widget<MaterialApp>(find.byType(MaterialApp));
  final themes = (light: app.theme!, dark: app.darkTheme!);
  // Unmounting the app disposes its controller.
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
  return themes;
}

/// The chat on a plain phone, drawn with [theme].
Future<JarvisController> pumpThemed(
  WidgetTester t,
  ThemeData theme, {
  Size size = const Size(402, 874),
  void Function(JarvisController)? seed,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  final c = JarvisController(FakeApi(), MemoryVault());
  await c.initialize();
  addTearDown(c.dispose);
  seed?.call(c);
  await t.pumpWidget(
    DuoLayoutScope(
      layout: ValueNotifier(DuoLayout.none),
      child: MaterialApp(
        theme: theme,
        home: JarvisHome(controller: c),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 400));
  return c;
}

void seedConversations(JarvisController c, int count) {
  for (var i = 0; i < count; i++) {
    c.newConversation().title = '会话标题 $i';
    c.current.messages.add(ChatMessage('user', '你好 $i'));
  }
}

/// Every label in the live semantics tree.
List<String> semanticLabels(WidgetTester t) {
  final out = <String>[];
  bool visit(SemanticsNode node) {
    if (node.label.isNotEmpty) out.add(node.label);
    node.visitChildren(visit);
    return true;
  }

  visit(t.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
  return out;
}

Finder inDrawer(Finder f) =>
    find.descendant(of: find.byType(Drawer), matching: f);

Future<void> openRename(WidgetTester t) async {
  await t.tap(find.byTooltip('会话操作').first);
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.text('重命名'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
}

class _Probe extends StatefulWidget {
  const _Probe(this.label, {super.key});
  final String label;
  static int created = 0;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.created++;
  }

  @override
  Widget build(BuildContext context) =>
      Semantics(liveRegion: true, child: Text(widget.label));
}

void main() {
  group('overlayOutgoing keeps the tree shape across a swap', () {
    Widget host(String label) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            SmoothSize(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                layoutBuilder: overlayOutgoing(),
                child: _Probe(label, key: ValueKey(label)),
              ),
            ),
          ],
        ),
      ),
    );

    testWidgets(
      'one State per child, and the leaving one is silent and inert',
      (t) async {
        final semantics = t.ensureSemantics();
        _Probe.created = 0;
        await t.pumpWidget(host('旧的提示'));
        await t.pumpWidget(host('新的提示'));
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(_Probe.created, 2, reason: 'the leaving child keeps its State');
        // Still painted while it fades, but no longer in the semantics tree (no second live-region announcement).
        expect(find.text('旧的提示'), findsOneWidget);
        final labels = semanticLabels(t);
        expect(labels, isNot(contains('旧的提示')), reason: '$labels');
        expect(labels, contains('新的提示'));
        bool ignores(String text) => t
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.text(text),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring;
        expect(ignores('旧的提示'), isTrue);
        expect(ignores('新的提示'), isFalse);
        await t.pump(const Duration(milliseconds: 400));
        expect(find.text('旧的提示'), findsNothing);
        expect(_Probe.created, 2);
        semantics.dispose();
      },
    );

    testWidgets('coming back during the fade does not throw', (t) async {
      await t.pumpWidget(host('甲'));
      await t.pumpWidget(host('乙'));
      await t.pump(const Duration(milliseconds: 30));
      await t.pumpWidget(host('甲'));
      await t.pump(const Duration(milliseconds: 30));
      expect(t.takeException(), isNull);
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('甲'), findsOneWidget);
      expect(find.text('乙'), findsNothing);
    });

    testWidgets('SmoothSize passes its clip on (hard edge by default)', (
      t,
    ) async {
      await t.pumpWidget(host('提示'));
      expect(
        t.widget<AnimatedSize>(find.byType(AnimatedSize)).clipBehavior,
        Clip.none,
      );
      await t.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SmoothSize(child: SizedBox(width: 10, height: 10)),
        ),
      );
      expect(
        t.widget<AnimatedSize>(find.byType(AnimatedSize)).clipBehavior,
        Clip.hardEdge,
      );
    });
  });

  testWidgets('the leaving side mic is not cut off by the shrinking cluster', (
    t,
  ) async {
    await pumpPhone(t);
    await t.enterText(find.byKey(const Key('chat-input')), '你好');
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('chat-input')), '');
    await t.pump();
    await t.pump(const Duration(milliseconds: 48));
    final mic = find.byKey(const ValueKey('side-mic'));
    expect(mic, findsOneWidget, reason: 'still fading out');
    final cluster = find
        .ancestor(of: mic, matching: find.byType(AnimatedSize))
        .first;
    expect(t.renderObject<RenderAnimatedSize>(cluster).clipBehavior, Clip.none);
    // The mic reaches past the cluster's left edge as it shrinks: unclipped, it shows whole while it fades.
    expect(t.getRect(mic).left, lessThan(t.getRect(cluster).left));
    await t.pump(const Duration(seconds: 1));
    expect(mic, findsNothing);
    expect(t.takeException(), isNull);
  });

  group('composer voice / send button', () {
    for (final size in const [
      Size(375, 667), // SE
      Size(402, 874), // Pro
      Size(874, 402), // Pro on its side: the single-row composer
    ]) {
      testWidgets('one 36pt circle in a 48pt target at $size', (t) async {
        await pumpPhone(t, size: size);
        final frame = find.byKey(const Key('composer-frame'));
        final button = find
            .descendant(of: frame, matching: find.byType(IconButton))
            .last;
        Rect circle() => t.getRect(
          find.descendant(of: button, matching: find.byType(Material)).first,
        );
        final empty = circle();
        expect(empty.size, const Size(36, 36));
        expect(t.getSize(button), const Size(48, 48));
        if (size.width > size.height) {
          // Centred in the frame and level with the + button, not nudged up.
          final box = t.getRect(frame);
          expect(
            empty.top - box.top,
            closeTo(box.bottom - empty.bottom, .5),
            reason: '$empty in $box',
          );
          final plus = t.getRect(
            find.descendant(of: frame, matching: find.byIcon(Icons.add)),
          );
          expect(empty.center.dy, closeTo(plus.center.dy, .5));
        }
        await t.enterText(find.byKey(const Key('chat-input')), '你');
        await t.pump();
        for (var i = 0; i < 16; i++) {
          await t.pump(const Duration(milliseconds: 16));
          expect(circle().size, const Size(36, 36), reason: 'frame $i');
        }
        expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
        if (size.width > size.height) {
          final mic = t.getRect(
            find
                .descendant(
                  of: find.byKey(const ValueKey('side-mic')),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(mic.center.dy, closeTo(circle().center.dy, .5));
        }
        await t.pump(const Duration(seconds: 1));
        expect(t.takeException(), isNull);
      });
    }
  });

  group('dialogs', () {
    for (final dark in [false, true]) {
      testWidgets(
        'phone rename field is a styled box with a counter (${dark ? 'dark' : 'light'})',
        (t) async {
          final themes = await appThemes(t);
          final theme = dark ? themes.dark : themes.light;
          await pumpThemed(t, theme, seed: (c) => seedConversations(c, 2));
          await openDrawer(t);
          await openRename(t);
          final decorator = t.widget<InputDecorator>(
            find.descendant(
              of: find.byKey(const Key('rename-field')),
              matching: find.byType(InputDecorator),
            ),
          );
          expect(decorator.decoration.filled, isTrue);
          final fill = decorator.decoration.fillColor;
          expect(fill, isNotNull);
          expect(fill, isNot(theme.dialogTheme.backgroundColor));
          expect(
            find.textContaining(RegExp(r'^\d+/60$')),
            findsOneWidget,
            reason: 'the length counter',
          );
          // Semibold title like the other headings, not Material's regular 24pt headline.
          final title = t
              .renderObject<RenderParagraph>(find.text('重命名会话'))
              .text
              .style!;
          expect(title.fontWeight, FontWeight.w600);
          expect(title.fontSize, 20);
          expect(theme.dialogTheme.titleTextStyle?.fontWeight, FontWeight.w600);
          await t.tap(find.widgetWithText(TextButton, '取消'));
          await t.pump(const Duration(seconds: 1));
        },
      );
    }

    testWidgets('foldable rename title: same weight, one size up', (t) async {
      await pumpHome(t, duoOuter, size: const Size(466, 678));
      await t.tap(find.byKey(const Key('duo-rail-sidebar')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await openRename(t);
      final title = t
          .renderObject<RenderParagraph>(find.text('重命名会话'))
          .text
          .style!;
      expect(title.fontWeight, FontWeight.w600);
      expect(title.fontSize, 22);
      await t.tap(find.widgetWithText(TextButton, '取消'));
      await t.pump(const Duration(seconds: 1));
    });
  });

  group('sidebar colours', () {
    for (final dark in [false, true]) {
      testWidgets(
        '${dark ? 'dark' : 'light'}: search field, new chat, selected row',
        (t) async {
          final themes = await appThemes(t);
          final theme = dark ? themes.dark : themes.light;
          final scheme = theme.colorScheme;
          final c = await pumpThemed(
            t,
            theme,
            seed: (c) => seedConversations(c, 7),
          );
          await openDrawer(t);
          final background = t
              .widget<Drawer>(find.byType(Drawer))
              .backgroundColor;
          final fill = t
              .widget<InputDecorator>(
                find.descendant(
                  of: find.byKey(const Key('conversation-search')),
                  matching: find.byType(InputDecorator),
                ),
              )
              .decoration
              .fillColor;
          expect(
            fill,
            isNot(background),
            reason: 'the field shows on the sidebar',
          );
          expect(
            fill,
            dark
                ? scheme.surfaceContainerHigh
                : theme.inputDecorationTheme.fillColor,
          );
          // New chat: a quiet tinted button in both themes, never the primary fill.
          final newChat = t.widget<Material>(
            find
                .descendant(
                  of: find.byKey(const Key('new-conversation')),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(newChat.color, isNot(scheme.primary));
          expect(
            newChat.color,
            dark ? scheme.surfaceContainerHighest : scheme.secondaryContainer,
          );
          expect(
            newChat.color!.computeLuminance(),
            lessThan(dark ? .1 : 1),
            reason: 'dark: no near-white button',
          );
          // Selected row: onSurface text on the raised surface, in both themes.
          final selected = c.current.title;
          final style = t
              .renderObject<RenderParagraph>(
                inDrawer(find.text(selected)).first,
              )
              .text
              .style!;
          expect(style.color, scheme.onSurface);
          expect(style.fontWeight, FontWeight.w600);
          final other = t
              .renderObject<RenderParagraph>(
                inDrawer(find.text('会话标题 0')).first,
              )
              .text
              .style!;
          expect(other.fontWeight, isNot(FontWeight.w600));
          await t.pump(const Duration(seconds: 1));
        },
      );
    }
  });

  group('interrupted reply', () {
    testWidgets('one retry, and the note above the actions', (t) async {
      await pumpPhone(
        t,
        seed: (c) {
          c
            ..authenticated = true
            ..model = 'test-model';
          c.current.messages
            ..add(ChatMessage('user', '你好'))
            ..add(
              ChatMessage(
                'assistant',
                '说到一半',
                status: 'interrupted',
                error: '网络中断',
              ),
            );
        },
      );
      expect(find.text('重试'), findsOneWidget);
      expect(find.byTooltip('重新生成'), findsNothing);
      final note = t.getRect(find.text('网络中断'));
      final copy = t.getRect(find.byTooltip('复制回复'));
      expect(note.bottom, lessThanOrEqualTo(copy.top));
      expect(note.top, greaterThan(t.getRect(find.text('说到一半')).bottom));
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('a finished reply keeps its regenerate icon', (t) async {
      await pumpPhone(
        t,
        seed: (c) {
          c
            ..authenticated = true
            ..model = 'test-model';
          c.current.messages
            ..add(ChatMessage('user', '你好'))
            ..add(ChatMessage('assistant', '回答'));
        },
      );
      expect(find.byTooltip('重新生成'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      await t.pump(const Duration(seconds: 2));
    });
  });

  group('landscape drawer', () {
    testWidgets('874x402: no brand row, settings beside new chat, five rows', (
      t,
    ) async {
      await pumpHome(
        t,
        DuoLayout.none,
        size: const Size(874, 402),
        insets: const EdgeInsets.only(bottom: 21),
        seed: (c) => seedConversations(c, 9),
      );
      await openDrawer(t);
      expect(inDrawer(find.text('JARVIS')), findsNothing);
      expect(inDrawer(find.text('设置')), findsNothing);
      final settings = t.getRect(
        inDrawer(find.byKey(const Key('sidebar-settings'))),
      );
      final newChat = t.getRect(find.byKey(const Key('new-conversation')));
      expect(newChat.height, 44);
      expect(settings.center.dy, closeTo(newChat.center.dy, .5));
      expect(settings.height, greaterThanOrEqualTo(44));
      final list = t.getRect(find.byKey(const Key('conversation-list')));
      final rows = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'conversation-surface-',
            ),
      );
      final whole = rows
          .evaluate()
          .map((e) => t.getRect(find.byWidget(e.widget)))
          .where((r) => r.top >= list.top - .5 && r.bottom <= list.bottom + .5)
          .length;
      expect(whole, greaterThanOrEqualTo(5), reason: 'list $list');
      // The settings button still opens settings.
      await t.tap(inDrawer(find.byKey(const Key('sidebar-settings'))));
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      expect(find.byType(SettingsPage), findsOneWidget);
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull);
    });

    testWidgets('portrait keeps the brand row and the settings row', (t) async {
      await pumpPhone(
        t,
        size: const Size(402, 874),
        seed: (c) => seedConversations(c, 9),
      );
      await openDrawer(t);
      expect(inDrawer(find.text('JARVIS')), findsOneWidget);
      expect(inDrawer(find.text('设置')), findsOneWidget);
      expect(find.byKey(const Key('sidebar-settings')), findsNothing);
      expect(t.getRect(find.byKey(const Key('new-conversation'))).height, 53);
      await t.pump(const Duration(seconds: 1));
    });
  });
}
