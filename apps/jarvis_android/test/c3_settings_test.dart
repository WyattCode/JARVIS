import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/attachments.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';
import 'package:jarvis_android/ui/voice_picker.dart';

import 'c2_support.dart';
import 'c3_support.dart';
import 'voice_support.dart' show wavBytes;

const wideFold = Size(951, 669);
const foldInsets = EdgeInsets.only(right: 84, bottom: 34);

void main() {
  group('dialogs', () {
    // Half-folded in landscape the dialog sits in the pane right of the crease, centred in it. The system strip is
    // taken off once (it used to be taken off twice and left a ~200 pt sliver off centre).
    for (final scale in [1.0, 2.4]) {
      testWidgets('half-folded: delete-all stays in the right pane x$scale', (
        t,
      ) async {
        final c = await pumpSettings3(
          t,
          size: wideFold,
          insets: foldInsets,
          layout: halfFolded,
          scale: scale,
        );
        await reveal(t, '删除全部会话');
        await t.tap(find.text('删除全部会话'));
        await t.pumpAndSettle();
        final r = dialogSurface(t);
        expect(r.left, greaterThanOrEqualTo(rightPane.left));
        expect(r.right, lessThanOrEqualTo(rightPane.right));
        expect(r.center.dx, closeTo((rightPane.left + rightPane.right) / 2, 1));
        expect(r.width, greaterThan(280), reason: 'not a sliver');
        expect(t.takeException(), isNull);
        await t.tap(find.text('取消'));
        await t.pumpAndSettle();
        await end(t, c);
      });
    }

    testWidgets('flat with the strip: centred in the content area', (t) async {
      final c = await pumpSettings3(
        t,
        size: wideFold,
        insets: foldInsets,
        layout: flatLandscape,
      );
      await reveal(t, '删除全部会话');
      await t.tap(find.text('删除全部会话'));
      await t.pumpAndSettle();
      final r = dialogSurface(t);
      expect(r.right, lessThanOrEqualTo(867));
      expect(r.center.dx, closeTo(867 / 2, 1));
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await end(t, c);
    });

    testWidgets('half-folded in portrait: below the crease', (t) async {
      final crease = DuoLayout.fromMap({
        'edge': 'none',
        'width': 669.0,
        'height': 951.0,
        'safe': {'left': 0.0, 'top': 54.0, 'right': 0.0, 'bottom': 34.0},
        'regions': [
          {
            'kind': 'division',
            'active': true,
            'x': 0.0,
            'y': 455.5,
            'w': 669.0,
            'h': 40.0,
          },
        ],
      });
      final c = await pumpSettings3(
        t,
        size: const Size(669, 951),
        insets: const EdgeInsets.only(top: 54, bottom: 34),
        layout: crease,
      );
      await reveal(t, '退出登录');
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      expect(dialogSurface(t).top, greaterThanOrEqualTo(495.5));
      expect(t.takeException(), isNull);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await end(t, c);
    });

    testWidgets('delete-all says it cannot be undone and names its button', (
      t,
    ) async {
      final c = await pumpSettings3(t);
      await reveal(t, '删除全部会话');
      await t.tap(find.text('删除全部会话'));
      await t.pumpAndSettle();
      expect(find.textContaining('无法撤销'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '删除全部'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await end(t, c);
    });

    testWidgets('delete-all removes the conversations, says so, and taps', (
      t,
    ) async {
      final haptics = recordHaptics(t);
      final c = await pumpSettings3(t);
      c.current.messages.add(ChatMessage('user', '你好'));
      await reveal(t, '删除全部会话');
      await t.tap(find.text('删除全部会话'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, '删除全部'));
      await t.pumpAndSettle();
      expect(c.current.messages, isEmpty);
      expect(find.text('已删除全部会话'), findsOneWidget);
      expect(haptics, contains('HapticFeedbackType.mediumImpact'));
      await t.pump(const Duration(seconds: 4));
      await end(t, c);
    });

    testWidgets('delete-all checks running tasks before the dialog', (t) async {
      final c = await pumpSettings3(t);
      c.current.tasks.add(
        MediaTask(id: 'task', kind: 'video', prompt: '测试', args: {}),
      );
      await reveal(t, '删除全部会话');
      await t.tap(find.text('删除全部会话'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('请先结束通话或等待当前任务完成'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      await end(t, c);
    });

    testWidgets('logout explains what stays and what stops', (t) async {
      final c = await pumpSettings3(t);
      await reveal(t, '退出登录');
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      expect(find.textContaining('仍保存在这台设备上'), findsOneWidget);
      expect(find.textContaining('中断'), findsOneWidget);
      expect(find.text('退出并清除本机数据'), findsNothing, reason: '没有接线时隐藏');
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await end(t, c);
    });

    testWidgets('logout and clear asks twice, then calls the callback', (
      t,
    ) async {
      var cleared = 0;
      final c = await pumpSettings3(
        t,
        onLogoutAndClear: () async {
          cleared++;
          return true;
        },
      );
      await reveal(t, '退出登录');
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      await t.tap(find.text('退出并清除本机数据'));
      await t.pumpAndSettle();
      expect(find.text('清除本机数据？'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(cleared, 0);
      expect(c.authenticated, isTrue);
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      await t.tap(find.text('退出并清除本机数据'));
      await t.pumpAndSettle();
      await t.tap(find.text('退出并清除'));
      await t.pumpAndSettle();
      expect(cleared, 1);
      await end(t, c);
    });

    testWidgets('a failed erase says so', (t) async {
      final c = await pumpSettings3(t, onLogoutAndClear: () async => false);
      await reveal(t, '退出登录');
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      await t.tap(find.text('退出并清除本机数据'));
      await t.pumpAndSettle();
      await t.tap(find.text('退出并清除'));
      await t.pumpAndSettle();
      expect(find.text('未能清除本机数据，请稍后重试'), findsOneWidget);
      await end(t, c);
    });

    testWidgets('read-only storage hides the erase option', (t) async {
      final vault = UnreadableVault();
      final c = await pumpSettings3(
        t,
        vault: vault,
        onLogoutAndClear: () async => true,
      );
      expect(c.storageReadOnly, isTrue);
      await reveal(t, '退出登录');
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      expect(find.text('退出并清除本机数据'), findsNothing);
      expect(find.widgetWithText(FilledButton, '退出登录'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await end(t, c);
    });

    // The dialogs of this page on every device: no overflow, buttons 44 pt and inside the safe area.
    final poses = [...straightPoses, ...foldPoses];
    for (final pose in poses) {
      for (final scale in textScales) {
        for (final brightness in Brightness.values) {
          testWidgets('logout dialog ${pose.name} x$scale ${brightness.name}', (
            t,
          ) async {
            final layout = switch (pose.name) {
              'outer' => outerDisplay,
              'inner landscape' => flatLandscape,
              _ => DuoLayout.none,
            };
            final c = await pumpSettings3(
              t,
              size: pose.size,
              insets: pose.insets,
              layout: layout,
              scale: scale,
              brightness: brightness,
              onLogoutAndClear: () async => true,
            );
            await reveal(t, '退出登录');
            await t.tap(find.text('退出登录'));
            await t.pumpAndSettle();
            expect(t.takeException(), isNull);
            final safe = pose.safe;
            final surface = dialogSurface(t);
            expect(surface.left, greaterThanOrEqualTo(safe.left - .5));
            expect(surface.right, lessThanOrEqualTo(safe.right + .5));
            expect(surface.top, greaterThanOrEqualTo(safe.top - .5));
            expect(surface.bottom, lessThanOrEqualTo(safe.bottom + .5));
            final buttons = find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.bySubtype<ButtonStyleButton>(),
                )
                .evaluate();
            expect(buttons.length, 3, reason: '取消 / 退出并清除本机数据 / 退出登录');
            for (final button in buttons) {
              final r = t.getRect(find.byWidget(button.widget));
              expect(r.height, greaterThanOrEqualTo(44 - .5));
            }
            await t.tap(find.text('取消'));
            await t.pumpAndSettle();
            await end(t, c);
          });
        }
      }
    }
  });

  group('voice previews', () {
    Finder playButton(String name) => find.byTooltip('试听 $name');

    testWidgets('the spinner shows while the clip downloads, and a tap stops', (
      t,
    ) async {
      final api = PreviewApi();
      final c = await pumpSettings3(t, api: api);
      await reveal(t, '星衡');
      await t.tap(playButton('星衡'));
      await t.pump();
      await t.pump();
      expect(c.voice.previewing, isTrue, reason: 'the session is busy at once');
      expect(find.byTooltip('正在加载试听'), findsOneWidget);
      expect(find.byTooltip('停止试听'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(VoiceChoiceRow),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      // Tapping the spinner cancels the load.
      await t.tap(find.byTooltip('正在加载试听'));
      await t.pump();
      // Stopping waits on a root-zone future (a stream cancel): let the real event loop turn.
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
      expect(c.voice.previewing, isFalse);
      expect(find.byTooltip('正在加载试听'), findsNothing);
      expect(playButton('星衡'), findsOneWidget);
      expect(api.previews, 1);
      await end(t, c);
    });

    testWidgets('once audio starts the button reads stop', (t) async {
      final api = PreviewApi();
      final c = await pumpSettings3(t, api: api);
      await reveal(t, '星衡');
      await t.tap(playButton('星衡'));
      await t.pump();
      await t.pump();
      api.clip.complete(wavBytes());
      await t.pump();
      await t.pump();
      expect(find.byTooltip('停止试听'), findsOneWidget);
      expect(find.byTooltip('正在加载试听'), findsNothing);
      await t.tap(find.byTooltip('停止试听'));
      await t.pump();
      await t.pump();
      expect(c.voice.previewing, isFalse);
      await end(t, c);
    });

    testWidgets('a failed call leaves no red text in settings', (t) async {
      final c = await pumpSettings3(t);
      c.voice.error = '需要麦克风权限才能语音通话，请在系统设置中允许';
      c.notifyDraftSuggestion();
      await t.pump();
      await reveal(t, '星衡');
      expect(find.textContaining('麦克风权限'), findsNothing);
      c.voice.previewError = '试听暂时不可用，请重试；已选音色保持不变';
      c.notifyDraftSuggestion();
      await t.pump();
      expect(find.textContaining('试听暂时不可用'), findsOneWidget);
      await end(t, c);
    });

    testWidgets('the picker shows the spinner and hides a call failure', (
      t,
    ) async {
      final api = PreviewApi();
      final c = await pumpSettings3(t, api: api);
      c.voice.error = '需要麦克风权限才能语音通话，请在系统设置中允许';
      await t.pumpWidget(
        withLayout(
          DuoLayout.none,
          appHost(
            Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showVoicePicker(context, c),
                    child: const Text('开'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('开'));
      await t.pumpAndSettle();
      expect(find.textContaining('麦克风权限'), findsNothing);
      await t.tap(playButton('星衡'));
      await t.pump();
      await t.pump();
      expect(find.byTooltip('正在加载试听'), findsOneWidget);
      expect(find.byTooltip('停止试听'), findsNothing);
      await t.tap(find.text('完成'));
      await t.pumpAndSettle();
      await end(t, c);
    });
  });

  group('the tokens field', () {
    // The first FieldRow is the token limit.
    Finder field() => find.descendant(
      of: find.byType(FieldRow).first,
      matching: find.byType(TextField),
    );
    Future<JarvisController> open(WidgetTester t) async {
      final c = await pumpSettings3(t);
      await t.ensureVisible(field());
      await t.drag(
        find.byKey(const Key('settings-scroll')),
        const Offset(0, 150),
      );
      await t.pump();
      return c;
    }

    testWidgets('typing 1024 never flashes an error on the way', (t) async {
      final c = await open(t);
      await t.tap(field());
      for (final text in ['1', '10', '102', '1024']) {
        await t.enterText(field(), text);
        await t.pump();
        expect(find.textContaining('请输入16至32768'), findsNothing, reason: text);
      }
      expect(c.settings.maxTokens, 1024);
      await t.pump(const Duration(seconds: 2));
      expect(find.textContaining('请输入16至32768'), findsNothing);
      await end(t, c);
    });

    testWidgets('an invalid value is reported after a pause, then restored', (
      t,
    ) async {
      final c = await open(t);
      c.settings.maxTokens = 512;
      await t.tap(field());
      await t.enterText(field(), '5');
      await t.pump();
      expect(find.textContaining('请输入16至32768'), findsNothing);
      await t.pump(const Duration(seconds: 1));
      expect(find.textContaining('请输入16至32768'), findsOneWidget);
      expect(
        c.settings.maxTokens,
        512,
        reason: 'the old value stays in effect',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      await t.pump();
      expect(t.widget<TextField>(field()).controller!.text, '512');
      expect(find.textContaining('请输入16至32768'), findsNothing);
      await end(t, c);
    });

    testWidgets('a 完成 key appears with focus and hides the keyboard', (
      t,
    ) async {
      final c = await open(t);
      expect(find.byKey(const Key('tokens-done')), findsNothing);
      await t.tap(field());
      await t.pump();
      final done = find.byKey(const Key('tokens-done'));
      expect(done, findsOneWidget);
      expect(t.getSize(done).height, greaterThanOrEqualTo(44));
      await t.tap(done);
      await t.pump();
      expect(find.byKey(const Key('tokens-done')), findsNothing);
      await end(t, c);
    });
  });

  group('data rows', () {
    testWidgets('a second tap on export waits for the first', (t) async {
      final gate = Completer<bool>();
      var saves = 0;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NativeFiles.channel,
        (call) async {
          if (call.method == 'save') {
            saves++;
            return gate.future;
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          NativeFiles.channel,
          null,
        ),
      );
      final c = await pumpSettings3(t);
      await reveal(t, '导出会话备份');
      Future<void> settle() async {
        // The export writes real files: let the real zone's IO finish.
        for (var i = 0; i < 6; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await t.pump();
        }
      }

      await t.tap(find.text('导出会话备份'));
      await t.pump();
      await settle();
      expect(
        t.widget<ListTile>(find.widgetWithText(ListTile, '导入会话备份')).enabled,
        isFalse,
      );
      // While it runs the row says so, and the other rows wait.
      expect(find.text('正在导出…'), findsOneWidget);
      await t.tap(find.text('正在导出…'), warnIfMissed: false);
      await t.tap(find.text('导入会话备份'), warnIfMissed: false);
      await settle();
      expect(saves, 1);
      gate.complete(true);
      await settle();
      expect(
        t.widget<ListTile>(find.widgetWithText(ListTile, '导出会话备份')).enabled,
        isTrue,
      );
      expect(find.textContaining('备份未能导出'), findsNothing);
      await end(t, c);
    });

    testWidgets('importing a backup without conversations says so', (t) async {
      final original = SettingsPage.pickBackup;
      addTearDown(() => SettingsPage.pickBackup = original);
      final gate = Completer<int?>();
      var picks = 0;
      SettingsPage.pickBackup = (_) {
        picks++;
        return gate.future;
      };
      final c = await pumpSettings3(t);
      await reveal(t, '导入会话备份');
      await t.tap(find.text('导入会话备份'));
      await t.pump();
      await t.tap(find.text('正在导入…'), warnIfMissed: false);
      await t.pump();
      expect(picks, 1);
      gate.complete(0);
      await t.pump();
      await t.pump();
      expect(find.text('没有可导入的会话'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      await end(t, c);
    });

    testWidgets('a cancelled picker is silent', (t) async {
      final original = SettingsPage.pickBackup;
      addTearDown(() => SettingsPage.pickBackup = original);
      SettingsPage.pickBackup = (_) async => null;
      final c = await pumpSettings3(t);
      await reveal(t, '导入会话备份');
      await t.tap(find.text('导入会话备份'));
      await t.pump();
      await t.pump();
      expect(find.byType(SnackBar), findsNothing);
      await end(t, c);
    });

    testWidgets('half-folded: notices stay in the right pane', (t) async {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final c = await pumpSettings3(
        t,
        size: wideFold,
        insets: foldInsets,
        layout: halfFolded,
      );
      await reveal(t, '复制诊断信息');
      await t.tap(find.text('复制诊断信息'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      // The SnackBar widget spans its margin; the visible bar is the Material inside.
      final notice = t.getRect(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(notice.left, greaterThanOrEqualTo(rightPane.left));
      expect(notice.right, lessThanOrEqualTo(rightPane.right));
      await t.pump(const Duration(seconds: 4));
      await end(t, c);
    });

    testWidgets('the privacy row opens the privacy page', (t) async {
      final c = await pumpSettings3(t);
      await reveal(t, '隐私与数据使用');
      await t.tap(find.text('隐私与数据使用'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('privacy-scroll')), findsOneWidget);
      await end(t, c);
    });
  });

  group('copy and structure', () {
    testWidgets('the tools explanation is the row subtitle, on or off', (
      t,
    ) async {
      final c = await pumpSettings3(t);
      const text = '打开后，助手可以在对话里直接生成图片和视频。';
      await t.ensureVisible(find.text('图片与视频工具'));
      expect(find.text(text), findsOneWidget);
      c.changeSettings((s) => s.tools = !c.settings.tools);
      await t.pump();
      expect(find.text(text), findsOneWidget);
      await end(t, c);
    });

    testWidgets('sections, anchors and wording', (t) async {
      final c = await pumpSettings3(t, size: const Size(402, 4000));
      double top(String text) => t.getTopLeft(find.text(text).last).dy;
      expect(find.text('音色'), findsNothing);
      expect(find.text('回答前等待时长'), findsNothing);
      expect(find.text('停顿多久算说完'), findsOneWidget);
      expect(find.text('语音与音色'), findsOneWidget);
      // Echo cancellation belongs to speech recognition (both modes), not to hands-free.
      expect(top('回声抑制'), greaterThan(top('语音识别')));
      expect(top('回声抑制'), lessThan(top('免按对话')));
      expect(top('语音与音色'), lessThan(top('语音识别')));
      await end(t, c);
    });

    testWidgets('theme names', (t) async {
      final c = await pumpSettings3(t);
      for (final name in ['浅色', '深色', '跟随系统']) {
        expect(find.text(name), findsOneWidget);
      }
      for (final old in ['白天', '黑夜', '系统']) {
        expect(find.text(old), findsNothing);
      }
      await end(t, c);
    });

    for (final brightness in Brightness.values) {
      testWidgets(
        'slider tracks stay visible on the card (${brightness.name})',
        (t) async {
          final c = await pumpSettings3(t, brightness: brightness);
          await t.ensureVisible(find.byKey(const Key('threshold-slider')));
          final slider = t.widget<Slider>(
            find.byKey(const Key('threshold-slider')),
          );
          final colors = Theme.of(t.element(find.byType(SettingsPage)))
              .colorScheme;
          final card = SettingsGroup.fill(colors);
          final track = Color.alphaBlend(slider.inactiveColor!, card);
          final la = track.computeLuminance(), lb = card.computeLuminance();
          final ratio =
              ((la > lb ? la : lb) + .05) / ((la > lb ? lb : la) + .05);
          // The light track is the earlier, already reviewed value; the dark one used to be the near-invisible default.
          expect(
            ratio,
            greaterThanOrEqualTo(brightness == Brightness.dark ? 2.2 : 1.5),
            reason: brightness.name,
          );
          await end(t, c);
        },
      );
    }
  });

  group('haptics', () {
    testWidgets('chips, voice rows, picker rows and the sensitivity slider', (
      t,
    ) async {
      final haptics = recordHaptics(t);
      final c = await pumpSettings3(t);
      await t.tap(find.byKey(const ValueKey('settings-chip-3')));
      await t.pumpAndSettle();
      expect(haptics.where((h) => h.endsWith('selectionClick')), isNotEmpty);
      haptics.clear();
      await reveal(t, '晨曦');
      await t.tap(find.text('晨曦'));
      await t.pump();
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      haptics.clear();
      await t.ensureVisible(find.byKey(const Key('threshold-slider')));
      await t.drag(
        find.byKey(const Key('settings-scroll')),
        const Offset(0, 150),
      );
      await t.pump();
      await t.drag(
        find.byKey(const Key('threshold-slider')),
        const Offset(-120, 0),
      );
      await t.pump();
      expect(haptics, isNotEmpty);
      await end(t, c);
    });
  });

  group('picker menu', () {
    testWidgets('the same surface as the action menu, in the right pane', (
      t,
    ) async {
      final c = await pumpSettings3(
        t,
        size: wideFold,
        insets: foldInsets,
        layout: halfFolded,
      );
      await t.tap(find.text('思考深度'));
      await t.pump();
      await t.pump();
      final surface = t.widget<Material>(
        find
            .ancestor(
              of: find.byType(PopupMenuItem<String>).first,
              matching: find.byType(Material),
            )
            .first,
      );
      final colors = Theme.of(t.element(find.byType(SettingsPage))).colorScheme;
      expect(
        surface.shape,
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.outlineVariant),
        ),
      );
      final items = t.getRect(find.byType(PopupMenuItem<String>).first);
      expect(items.left, greaterThanOrEqualTo(rightPane.left));
      expect(items.right, lessThanOrEqualTo(rightPane.right));
      expect(t.takeException(), isNull);
      await t.tap(find.text('低'));
      await t.pumpAndSettle();
      await end(t, c);
    });

    testWidgets('half-folded in portrait: clear of the crease', (t) async {
      final crease = DuoLayout.fromMap({
        'edge': 'none',
        'width': 669.0,
        'height': 951.0,
        'safe': {'left': 0.0, 'top': 54.0, 'right': 0.0, 'bottom': 34.0},
        'regions': [
          {
            'kind': 'division',
            'active': true,
            'x': 0.0,
            'y': 330.0,
            'w': 669.0,
            'h': 40.0,
          },
        ],
      });
      final c = await pumpSettings3(
        t,
        size: const Size(669, 951),
        insets: const EdgeInsets.only(top: 54, bottom: 34),
        layout: crease,
      );
      await t.tap(find.text('聊天模型'));
      await t.pumpAndSettle();
      for (final item in find.byType(PopupMenuItem<String>).evaluate()) {
        final r = t.getRect(find.byWidget(item.widget));
        expect(r.bottom <= 330 || r.top >= 370, isTrue, reason: '$r');
      }
      await t.tapAt(const Offset(5, 940));
      await t.pumpAndSettle();
      await end(t, c);
    });
  });
}
