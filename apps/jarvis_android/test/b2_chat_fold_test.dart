import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/media_widgets.dart';
import 'package:jarvis_android/ui/status_page.dart';

import 'b2_support.dart';
import 'b_chat_ui_test.dart' show halfFolded;
import 'duo_rail_test.dart' show duoLandscape, pumpHome;

/// Inner display in portrait, half-folded: the crease is a horizontal band at y 455.5..495.5.
DuoLayout portraitFold({bool active = true}) => DuoLayout.fromMap({
  'edge': 'none',
  'width': 669.0,
  'height': 951.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 0.0, 'bottom': 34.0},
  'regions': [
    {
      'kind': 'division',
      'active': active,
      'x': 0.0,
      'y': 455.5,
      'w': 669.0,
      'h': 40.0,
    },
  ],
});

final messages = find.byWidgetPredicate(
  (w) => w is ListView && w.key is PageStorageKey,
);

bool onCrease(Rect r) => r.right > 455.5 && r.left < 495.5;

void main() {
  group('header follows the column in a half-fold', () {
    for (final title in ['新会话', '八个汉字的标题啊', '十三个汉字组成的会话标题啊', '很长的标题' * 8]) {
      testWidgets('title ${title.length} chars stays off the crease', (
        t,
      ) async {
        await pumpHome(
          t,
          halfFolded,
          seed: (c) {
            c.current.title = title;
            c.current.messages.add(ChatMessage('user', '你好'));
          },
        );
        await t.pump(const Duration(milliseconds: 400));
        final row = t.getRect(
          find
              .ancestor(
                of: find.byKey(const Key('connection-dot')),
                matching: find.byType(InkWell),
              )
              .first,
        );
        expect(onCrease(row), isFalse, reason: '$row');
        expect(row.left, greaterThanOrEqualTo(495.5));
        expect(row.right, lessThanOrEqualTo(951 - 84));
        expect(row.height, greaterThanOrEqualTo(44));
        // The title starts at the composer frame's left edge.
        final text = t.getRect(find.byKey(const ValueKey('chat-heading-line')));
        final frame = t.getRect(find.byKey(const Key('composer-frame')));
        expect(text.left, closeTo(frame.left, .5));
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('flat unfolded: the title lines up with the composer frame', (
      t,
    ) async {
      await pumpHome(t, duoLandscape);
      final text = t.getRect(find.byKey(const ValueKey('chat-heading-line')));
      final frame = t.getRect(find.byKey(const Key('composer-frame')));
      expect(text.left, closeTo(frame.left, .5));
    });
  });

  group('docked sidebar toggled while half-folded', () {
    testWidgets('the column holds still, no frame overflows', (t) async {
      await pumpHome(
        t,
        halfFolded,
        seed: (c) => c.current.messages
          ..add(ChatMessage('user', '你好'))
          ..add(ChatMessage('assistant', '很长的回复。' * 40)),
      );
      final before = t.getRect(find.byKey(const Key('composer-frame')));
      for (final tooltip in ['收起会话', '展开会话']) {
        await t.tap(find.byTooltip(tooltip));
        await t.pump();
        for (var i = 0; i < 16; i++) {
          await t.pump(const Duration(milliseconds: 16));
          expect(t.takeException(), isNull);
          final now = t.getRect(find.byKey(const Key('composer-frame')));
          expect(now.left, closeTo(before.left, .01), reason: 'frame $i');
          expect(now.right, closeTo(before.right, .01), reason: 'frame $i');
          expect(
            t.widget<Opacity>(find.byKey(const Key('fold-fade'))).opacity,
            1,
          );
        }
      }
    });
  });

  group('window resize', () {
    testWidgets('a rotation takes the new geometry at once, without a fade', (
      t,
    ) async {
      final layout = ValueNotifier(halfFolded);
      await pumpHome(t, halfFolded, notifier: layout);
      // Rotate to a flat portrait window.
      t.view.physicalSize = const Size(669, 951);
      layout.value = DuoLayout.none;
      await t.pump();
      final fade = t.widget<Opacity>(find.byKey(const Key('fold-fade')));
      expect(fade.opacity, 1);
      final frame = t.getRect(find.byKey(const Key('composer-frame')));
      expect(frame.left, lessThan(100));
      expect(t.takeException(), isNull);
    });
  });

  group('fade', () {
    testWidgets('the column ignores touches while it is faded out', (t) async {
      final layout = ValueNotifier(duoLandscape);
      await pumpHome(t, duoLandscape, notifier: layout);
      layout.value = halfFolded;
      await t.pump();
      await t.pump(const Duration(milliseconds: 16));
      await t.pump(const Duration(milliseconds: 150));
      final ignore = t.widget<IgnorePointer>(
        find
            .descendant(
              of: find.byKey(const Key('fold-fade')),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(ignore.ignoring, isTrue);
      await t.pump(const Duration(milliseconds: 400));
    });

    testWidgets('the sidebar is not rebuilt on every frame of the fade', (
      t,
    ) async {
      final layout = ValueNotifier(duoLandscape);
      await pumpHome(t, duoLandscape, notifier: layout);
      layout.value = halfFolded;
      await t.pump();
      await t.pump(const Duration(milliseconds: 16));
      final sidebar = t.element(find.byKey(const Key('conversation-list')));
      var rebuilds = 0;
      final old = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget is SliverMultiBoxAdaptorWidget &&
            element == sidebar) {
          rebuilds++;
        }
      };
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      debugOnRebuildDirtyWidget = old;
      expect(rebuilds, 0);
    });

    testWidgets('the reading place survives the re-wrap', (t) async {
      final layout = ValueNotifier(duoLandscape);
      await pumpHome(
        t,
        duoLandscape,
        notifier: layout,
        seed: (c) {
          for (var i = 0; i < 30; i++) {
            c.current.messages
              ..add(ChatMessage('user', '问题 $i'))
              ..add(ChatMessage('assistant', '这是第 $i 个回答。' * 14));
          }
        },
      );
      final list = messages;
      await t.drag(list, const Offset(0, 3000));
      await t.pump();
      ScrollPosition position() => t
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position;
      final share = position().pixels / position().maxScrollExtent;
      layout.value = halfFolded;
      await t.pump();
      await t.pump(const Duration(milliseconds: 16));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      final after = position().pixels / position().maxScrollExtent;
      expect(after, closeTo(share, .06));
    });
  });

  group('portrait half-fold', () {
    testWidgets('the welcome cards sit under the crease', (t) async {
      await pumpHome(
        t,
        portraitFold(),
        size: const Size(669, 951),
        insets: const EdgeInsets.only(bottom: 34),
      );
      for (var i = 0; i < 4; i++) {
        final card = t.getRect(find.byKey(ValueKey('starter-$i')));
        expect(card.top, greaterThanOrEqualTo(495.5), reason: 'card $i $card');
      }
      final composer = t.getRect(find.byKey(const Key('composer-frame')));
      expect(composer.top, greaterThanOrEqualTo(495.5));
      expect(t.takeException(), isNull);
    });

    testWidgets('flat: the welcome page is where it was', (t) async {
      await pumpHome(
        t,
        portraitFold(active: false),
        size: const Size(669, 951),
        insets: const EdgeInsets.only(bottom: 34),
      );
      final card = t.getRect(find.byKey(const ValueKey('starter-0')));
      expect(card.top, lessThan(495.5));
    });

    testWidgets('a long draft with the keyboard up keeps the composer low', (
      t,
    ) async {
      final c = await pumpHome(
        t,
        portraitFold(),
        size: const Size(669, 951),
        insets: const EdgeInsets.only(bottom: 34),
        keyboard: 300,
      );
      c.setDraft(List.filled(8, '很长的一行').join('\n'));
      c.notifyDraftSuggestion();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      final composer = t.getRect(find.byKey(const Key('composer-frame')));
      expect(composer.top, greaterThanOrEqualTo(495.5));
      expect(t.takeException(), isNull);
      await t.pump(const Duration(seconds: 2)); // debounced save
    });
  });

  group('notices', () {
    testWidgets('a notice stays on the column half-folded', (t) async {
      await pumpHome(t, halfFolded);
      final context = t.element(find.byKey(const Key('composer-frame')));
      showNotice(context, '添加附件失败，请重试');
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      final bar = t.getRect(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(onCrease(bar), isFalse, reason: '$bar');
      expect(bar.left, greaterThanOrEqualTo(495.5));
    });

    testWidgets('a compact notice lines up with the composer frame', (t) async {
      await pumpHome(t, halfFolded);
      final context = t.element(find.byKey(const Key('composer-frame')));
      showNotice(context, '会话已删除', compact: true);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      final bar = t.getRect(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Material),
            )
            .first,
      );
      final frame = t.getRect(find.byKey(const Key('composer-frame')));
      expect(bar.left, closeTo(frame.left, 1));
    });
  });

  group('keyboard', () {
    testWidgets('settings and the status page take the keyboard down', (
      t,
    ) async {
      await pumpHome(t, duoLandscape);
      await t.tap(find.byKey(const Key('chat-input')));
      await t.pump();
      expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
      await t.tap(find.byKey(const Key('connection-dot')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(StatusPage), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>(),
        isNull,
      );
    });

    testWidgets('hiding the docked list drops the keyboard too', (t) async {
      await pumpHome(t, duoLandscape);
      await t.tap(find.byKey(const Key('chat-input')));
      await t.pump();
      await t.tap(find.byTooltip('收起会话'));
      await t.pump();
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>(),
        isNull,
      );
      await t.pump(const Duration(milliseconds: 400));
    });
  });

  group('composer and keyboard', () {
    testWidgets('8-10 pt above the keyboard, 22 pt above the home indicator', (
      t,
    ) async {
      await pumpHome(t, duoLandscape);
      final rest = t.getRect(find.byKey(const Key('composer-frame')));
      expect(rest.bottom, closeTo(669 - 22, 1.5));
      await pumpHome(t, duoLandscape, keyboard: 300);
      await t.pump(const Duration(milliseconds: 400));
      final typing = t.getRect(find.byKey(const Key('composer-frame')));
      expect(669 - 300 - typing.bottom, closeTo(10, 1));
    });

    testWidgets('a five-line draft leaves the messages 120 pt', (t) async {
      final c = await pumpHome(
        t,
        duoLandscape,
        keyboard: 300,
        seed: someMessages,
      );
      c.setDraft(List.filled(5, '一行文字').join('\n'));
      c.notifyDraftSuggestion();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      final list = t.getRect(messages);
      expect(list.height, greaterThanOrEqualTo(120));
      expect(t.takeException(), isNull);
      await t.pump(const Duration(seconds: 2)); // debounced save
    });
  });
}
