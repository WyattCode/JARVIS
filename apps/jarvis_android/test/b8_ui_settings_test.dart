import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/design_tokens.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';
import 'package:jarvis_android/ui/status_page.dart';

import 'c2_status_test.dart' show QueueStatusApi, status;
import 'c2_support.dart';
import 'c3_support.dart';
import 'support.dart';

/// A host that keeps animations on (the shared `appHost` turns them off).
Widget animatedHost(Widget home, {bool reduce = false}) => MaterialApp(
  theme: themeFor(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
    child: child!,
  ),
  home: Scaffold(body: Center(child: home)),
);

void main() {
  group('token field row', () {
    testWidgets('keeps its height when the field gains the focus', (t) async {
      final c = await pumpSettings3(t);
      await reveal(t, '回复长度上限（Token）');
      final row = find.byType(FieldRow).first;
      final before = t.getSize(row).height;
      await t.tap(find.byType(TextField).first);
      await t.pump();
      expect(find.byKey(const Key('tokens-done')), findsOneWidget);
      expect(t.getSize(row).height, before);
      await t.tap(find.byKey(const Key('tokens-done')));
      await t.pump();
      expect(t.getSize(row).height, before);
      await end(t, c);
    });

    testWidgets('a tap on the label focuses the field', (t) async {
      final c = await pumpSettings3(t);
      await reveal(t, '回复长度上限（Token）');
      expect(find.byKey(const Key('tokens-done')), findsNothing);
      await t.tap(find.text('回复长度上限（Token）'));
      await t.pump();
      expect(find.byKey(const Key('tokens-done')), findsOneWidget);
      await end(t, c);
    });

    testWidgets('the label takes the primary colour while focused', (t) async {
      final c = await pumpSettings3(t);
      await reveal(t, '助手指令');
      Color? labelColor() => t
          .widget<DefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('助手指令'),
                  matching: find.byType(DefaultTextStyle),
                )
                .first,
          )
          .style
          .color;
      final colors = Theme.of(t.element(find.byType(SettingsPage))).colorScheme;
      expect(labelColor(), colors.onSurface);
      await t.tap(find.text('助手指令'));
      await t.pump(const Duration(milliseconds: 400));
      expect(labelColor(), colors.primary);
      await end(t, c);
    });
  });

  group('data job', () {
    testWidgets('the logout row waits for an import, which says so', (t) async {
      final original = SettingsPage.pickBackup;
      addTearDown(() => SettingsPage.pickBackup = original);
      final gate = Completer<int?>();
      SettingsPage.pickBackup = (_) => gate.future;
      final c = await pumpSettings3(t);
      await reveal(t, '导入会话备份');
      bool enabled(String title) =>
          t.widget<ListTile>(find.widgetWithText(ListTile, title)).enabled;
      expect(enabled('退出登录'), isTrue);
      await t.tap(find.text('导入会话备份'));
      await t.pump();
      expect(find.text('正在导入…'), findsOneWidget);
      expect(find.text('导入会话备份'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is CircularProgressIndicator && w.semanticsLabel == '正在导入',
        ),
        findsOneWidget,
      );
      for (final title in ['导出会话备份', '删除全部会话', '退出登录']) {
        expect(enabled(title), isFalse, reason: title);
      }
      gate.complete(null);
      await t.pump();
      await t.pump();
      expect(enabled('退出登录'), isTrue);
      expect(find.text('导入会话备份'), findsOneWidget);
      await end(t, c);
    });

    testWidgets('the privacy row has a chevron, the others do not', (t) async {
      final c = await pumpSettings3(t);
      await reveal(t, '隐私与数据使用');
      final tile = find.widgetWithText(ListTile, '隐私与数据使用');
      expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, '复制诊断信息'),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsNothing,
      );
      await end(t, c);
    });
  });

  testWidgets('the three-button logout dialog puts 取消 at the bottom', (
    t,
  ) async {
    final c = await pumpSettings3(
      t,
      size: const Size(375, 812),
      onLogoutAndClear: () async => true,
    );
    await reveal(t, '退出登录');
    await t.tap(find.text('退出登录'));
    await t.pumpAndSettle();
    Finder button(String text) =>
        find.ancestor(of: find.text(text), matching: find.byType(TextButton));
    final keep = find.widgetWithText(FilledButton, '退出登录');
    final clear = button('退出并清除本机数据');
    final cancel = button('取消');
    final keepRect = t.getRect(keep),
        clearRect = t.getRect(clear),
        cancelRect = t.getRect(cancel);
    expect(keepRect.top, lessThan(clearRect.top));
    expect(clearRect.top, lessThan(cancelRect.top));
    // Full width and centred, 44 pt high.
    expect(clearRect.width, keepRect.width);
    expect(cancelRect.width, keepRect.width);
    expect(cancelRect.height, greaterThanOrEqualTo(44));
    final colors = Theme.of(t.element(find.byType(AlertDialog))).colorScheme;
    expect(
      t.widget<TextButton>(clear).style?.foregroundColor?.resolve({}),
      colors.error,
    );
    await t.tap(cancel);
    await t.pumpAndSettle();
    await end(t, c);
  });

  group('toggle row', () {
    testWidgets('a tap on the row gives the switch haptic and toggles', (
      t,
    ) async {
      final haptics = recordHaptics(t);
      final values = <bool>[];
      await t.pumpWidget(
        animatedHost(
          ToggleRow(title: '回声抑制', value: false, onChanged: values.add),
        ),
      );
      await t.tap(find.text('回声抑制'));
      await t.pump();
      expect(values, [true]);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
    });

    testWidgets('the switch still toggles by itself, without a second tick', (
      t,
    ) async {
      final haptics = recordHaptics(t);
      final values = <bool>[];
      await t.pumpWidget(
        animatedHost(
          ToggleRow(title: '回声抑制', value: false, onChanged: values.add),
        ),
      );
      await t.tap(find.byType(Switch));
      await t.pump();
      expect(values, [true]);
      // The test platform is not iOS, so the switch adds none of its own; the row did not fire on top of the switch.
      expect(haptics, isEmpty);
    });
  });

  group('SettingsGroup', () {
    Widget group(int rows, {bool reduce = false}) => animatedHost(
      SettingsGroup(
        children: [
          for (var i = 0; i < rows; i++)
            SizedBox(height: 50, child: Text('row $i')),
        ],
      ),
      reduce: reduce,
    );

    testWidgets('grows and shrinks with its rows', (t) async {
      await t.pumpWidget(group(1));
      final one = t.getSize(find.byType(SettingsGroup)).height;
      await t.pumpWidget(group(3));
      await t.pump();
      await t.pump(const Duration(milliseconds: 80));
      final mid = t.getSize(find.byType(SettingsGroup)).height;
      expect(mid, greaterThan(one));
      await t.pumpAndSettle();
      final three = t.getSize(find.byType(SettingsGroup)).height;
      expect(three, greaterThan(mid));
      expect(three, one + 2 * 51);
    });

    testWidgets('jumps when motion is reduced', (t) async {
      await t.pumpWidget(group(1, reduce: true));
      final one = t.getSize(find.byType(SettingsGroup)).height;
      await t.pumpWidget(group(3, reduce: true));
      await t.pump();
      expect(t.getSize(find.byType(SettingsGroup)).height, one + 2 * 51);
    });

    testWidgets('divider indent follows the leading icon', (t) async {
      await t.pumpWidget(
        animatedHost(
          const SettingsGroup(
            dividerIndent: SettingsGroup.iconIndent,
            children: [Text('a'), Text('b')],
          ),
        ),
      );
      expect(t.widget<Divider>(find.byType(Divider)).indent, 56);
    });
  });

  group('VoiceChoiceRow', () {
    Widget row({
      bool selected = false,
      bool playing = false,
      bool loading = false,
    }) => animatedHost(
      VoiceChoiceRow(
        name: '晨曦',
        description: '',
        selected: selected,
        playing: playing,
        loading: loading,
        onSelect: () {},
        onPlay: () {},
      ),
    );

    testWidgets('play, spinner and stop pop into each other', (t) async {
      await t.pumpWidget(row());
      await t.pumpWidget(row(loading: true));
      await t.pump(const Duration(milliseconds: 60));
      // Mid-way both are on screen.
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // (the spinner never settles: a fixed wait)
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      await t.pumpWidget(row(playing: true));
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('the check mark appears with the selection', (t) async {
      await t.pumpWidget(row());
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      await t.pumpWidget(row(selected: true));
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });
  });

  group('theme tiles', () {
    testWidgets('shrink to .96 while pressed and come back', (t) async {
      await t.pumpWidget(
        animatedHost(ThemeSwatches(value: 'system', onChanged: (_) {})),
      );
      double scale() => t
          .widget<AnimatedScale>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('theme-dark')),
                  matching: find.byType(AnimatedScale),
                )
                .first,
          )
          .scale;
      expect(scale(), 1);
      // (the host gives the tile the whole height: press on the little screen at its top)
      final tile = t.getRect(find.byKey(const ValueKey('theme-dark')));
      final g = await t.startGesture(tile.topCenter + const Offset(0, 40));
      await t.pump();
      expect(scale(), closeTo(.96, 1e-9));
      await g.up();
      await t.pump();
      expect(scale(), 1);
    });
  });

  testWidgets('page notices last longer for longer texts, up to 7 s', (
    _,
  ) async {
    expect(noticeDuration('已复制'), const Duration(seconds: 3));
    expect(noticeDuration('字' * 40), const Duration(milliseconds: 4800));
    expect(noticeDuration('字' * 200), const Duration(seconds: 7));
  });

  testWidgets('page notices sit in line with the 20 pt card margins', (
    t,
  ) async {
    late BuildContext host;
    await t.pumpWidget(
      appHost(
        Scaffold(
          body: Builder(
            builder: (context) {
              host = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    showPageNotice(host, '已复制');
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final bar = t.getRect(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(bar.left, 20);
    expect(t.view.physicalSize.width / t.view.devicePixelRatio - bar.right, 20);
    await t.pumpAndSettle(const Duration(seconds: 4));
  });

  group('status page states', () {
    Future<(JarvisController, QueueStatusApi)> open(
      WidgetTester t, {
      bool reduce = false,
    }) async {
      sizeWindow(t, const Size(402, 874), const EdgeInsets.only(top: 62));
      final api = QueueStatusApi();
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: themeFor(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
            child: child!,
          ),
          home: StatusPage(controller: c),
        ),
      );
      await t.pump();
      return (c, api);
    }

    testWidgets('loading cross-fades into the list', (t) async {
      final (_, api) = await open(t);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      api.pending.single.complete(status([('语音', 'ready')]));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('语音'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('语音'), findsOneWidget);
    });

    testWidgets('with reduced motion the states swap at once', (t) async {
      final (_, api) = await open(t, reduce: true);
      api.pending.single.complete(status([('语音', 'ready')]));
      await t.pump();
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('语音'), findsOneWidget);
    });

    testWidgets('the failed refresh line and the bar ease in and out', (
      t,
    ) async {
      final (_, api) = await open(t);
      api.pending.single.complete(status([('语音', 'ready')]));
      await t.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await t.tap(find.byTooltip('刷新状态'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      api.pending.last.completeError(Exception('down'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      // Fading out while the failure line grows in.
      expect(find.text('刷新失败，显示的是上一次的状态'), findsOneWidget);
      await t.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byType(InlineError), findsOneWidget);
    });

    testWidgets('dots use the shared status colours', (t) async {
      final (_, api) = await open(t);
      api.pending.single.complete(status([('甲', 'ready'), ('乙', 'busy')]));
      await t.pumpAndSettle();
      final ctx = t.element(find.byType(StatusPage));
      final colors = [
        for (final i in t.widgetList<Icon>(find.byIcon(Icons.circle))) i.color,
      ];
      expect(colors, [JarvisColors.success(ctx), JarvisColors.warning(ctx)]);
    });
  });
}
