import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/attachments.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/attachment_manager.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import '../test/support.dart';

void window(WidgetTester t) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(623, 425);
  t.view.viewPadding = const FakeViewPadding(top: 46, bottom: 20);
  t.view.padding = const FakeViewPadding(top: 46);
  t.view.viewInsets = const FakeViewPadding(bottom: 320);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetViewPadding);
  addTearDown(t.view.resetPadding);
  addTearDown(t.view.resetViewInsets);
}

Future<void> pause(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
    'Picker failure is readable above the sheet, retry clears it and preserves draft',
    (t) async {
      window(t);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.current.draft = '保留这段草稿';
      c.current.pendingAttachments.add(
        Attachment(
          id: 'a',
          name: '长文件名称：折叠屏交互与兼容性审核建议.txt',
          mime: 'text/plain',
          kind: 'document',
          text: '预览',
          size: 2048,
        ),
      );
      var calls = 0;
      const ch = MethodChannel('plugins.flutter.io/file_selector');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, (
        call,
      ) async {
        calls++;
        if (calls == 1) {
          throw PlatformException(
            code: 'internal_platform_details',
            message: 'private-error',
          );
        }
        return <String>[];
      });
      addTearDown(
        () =>
            t.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, null),
      );
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await pause(t);
      await t.tap(find.byTooltip('管理已选附件'));
      t.view.viewInsets = FakeViewPadding.zero;
      t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
      await pause(t);
      final name = find.descendant(
        of: find.byType(AttachmentManager),
        matching: find.text(c.current.pendingAttachments.single.name),
      );
      expect(t.widget<Text>(name).maxLines, 2);
      expect(find.textContaining('2.0 KB'), findsOneWidget);
      await t.tap(find.text('添加附件'));
      await pause(t);
      expect(find.text('无法添加附件，请重试').hitTestable(), findsOneWidget);
      expect(find.text('重试').hitTestable(), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('private-error'), findsNothing);
      expect(c.current.draft, '保留这段草稿');
      expect(c.current.pendingAttachments, hasLength(1));
      await t.tap(find.text('重试'));
      await pause(t);
      expect(calls, 2);
      expect(find.byKey(const Key('attachment-error')), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Dismissed manager reports a late failure once without setState after dispose',
    (t) async {
      window(t);
      t.view.viewInsets = FakeViewPadding.zero;
      t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final pending = Completer<void>();
      final errors = <Object>[];
      var calls = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentManager(
              controller: c,
              ownerId: c.current.id,
              onAdd: () {
                calls++;
                return pending.future;
              },
              onDetachedError: errors.add,
            ),
          ),
        ),
      );
      await pause(t);
      await t.tap(find.text('添加附件'));
      await t.pump();
      expect(find.text('正在添加'), findsOneWidget);
      expect(
        t.widget<TextButton>(find.widgetWithText(TextButton, '正在添加')).onPressed,
        isNull,
      );
      expect(calls, 1);
      await t.pumpWidget(const SizedBox());
      pending.completeError(PlatformException(code: 'failed'));
      await pause(t);
      expect(errors, hasLength(1));
      expect(t.takeException(), isNull);
      c.dispose();
    },
  );
  testWidgets(
    'Manager is scrollable at large font and cannot modify a different conversation',
    (t) async {
      window(t);
      t.view.viewInsets = FakeViewPadding.zero;
      t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final owner = c.current.id;
      for (var i = 0; i < 4; i++) {
        c.current.pendingAttachments.add(
          Attachment(
            id: '$i',
            name: '很长的文件名用于检查系统大字号的文件列表$i.txt',
            mime: 'text/plain',
            kind: 'document',
            size: 2048,
          ),
        );
      }
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: AttachmentManager(
              controller: c,
              ownerId: owner,
              onAdd: () async {},
              onDetachedError: (_) {
                fail('unexpected');
              },
            ),
          ),
        ),
      );
      await pause(t);
      expect(t.takeException(), isNull);
      await t.drag(find.byType(ListView), const Offset(0, -500));
      await pause(t);
      expect(
        find.byKey(const ValueKey('selected-3')).hitTestable(),
        findsOneWidget,
      );
      c.newConversation();
      await pause(t);
      expect(find.text('会话已切换'), findsOneWidget);
      expect(find.byTooltip('移除 很长的文件名用于检查系统大字号的文件列表3.txt'), findsNothing);
      expect(
        t.widget<TextButton>(find.widgetWithText(TextButton, '添加附件')).onPressed,
        isNull,
      );
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  test(
    'Validation messages remain specific while platform internals are hidden',
    () {
      expect(
        attachmentErrorMessage(const JarvisException('单个附件不能超过20MB')),
        '单个附件不能超过20MB',
      );
      expect(
        attachmentErrorMessage(PlatformException(code: 'private')),
        '无法添加附件，请重试',
      );
    },
  );
}
