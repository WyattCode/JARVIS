import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/message_parts.dart';

/// The parts of a reply, as the iOS app draws them.
void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  group('the thinking of a reply', () {
    testWidgets(
      'is folded, 48 high, and opens to words with a bar beside them',
      (t) async {
        var opened = 0;
        await t.pumpWidget(
          host(
            PageStorage(
              bucket: PageStorageBucket(),
              child: ReasoningBlock(
                key: const PageStorageKey('r'),
                text: '先看附件，再回答',
                size: 17,
                thinking: false,
                onOpened: () => opened++,
              ),
            ),
          ),
        );
        expect(find.text('思考过程'), findsOneWidget);
        expect(find.text('先看附件，再回答'), findsNothing);
        expect(t.getSize(find.byKey(const Key('reasoning-toggle'))).height, 48);
        await t.tap(find.text('思考过程'));
        await t.pump();
        expect(find.text('先看附件，再回答'), findsOneWidget);
        expect(opened, 1);
        // The words are a little smaller than the reply's own, and quiet.
        final words = t.widget<SelectableText>(find.byType(SelectableText));
        expect(words.style!.fontSize, 15.5);
        expect(words.style!.height, 1.6);
        await t.tap(find.text('思考过程'));
        await t.pump();
        expect(find.text('先看附件，再回答'), findsNothing);
        expect(opened, 1);
      },
    );

    testWidgets('says it is thinking while the reply has no words', (t) async {
      await t.pumpWidget(
        host(const ReasoningBlock(text: '…', size: 17, thinking: true)),
      );
      expect(find.text('思考中…'), findsOneWidget);
      expect(find.text('思考过程'), findsNothing);
    });

    testWidgets('stays open when the list is rebuilt around it', (t) async {
      final bucket = PageStorageBucket();
      Widget screen() => host(
        PageStorage(
          bucket: bucket,
          child: const ReasoningBlock(
            key: PageStorageKey('r'),
            text: '内容',
            size: 17,
            thinking: false,
          ),
        ),
      );
      await t.pumpWidget(screen());
      await t.tap(find.text('思考过程'));
      await t.pump();
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(screen());
      expect(find.text('内容'), findsOneWidget);
    });
  });

  testWidgets('a status row has a small spinner and quiet words', (t) async {
    await t.pumpWidget(host(const MessageStatusRow('正在思考…')));
    expect(find.text('正在思考…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      t.getSize(find.byType(CircularProgressIndicator)),
      const Size(14, 14),
    );
    final text = t.widget<Text>(find.text('正在思考…'));
    expect(text.style!.fontSize, 13);
    await t.pumpWidget(const SizedBox());
  });

  group('the copy button', () {
    testWidgets('turns to a check for a moment, with a tick, and is 44 wide', (
      t,
    ) async {
      final calls = <MethodCall>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await t.pumpWidget(host(const CopyReplyButton(text: '回答')));
      expect(t.getSize(find.byType(IconButton)), const Size(44, 44));
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      await t.tap(find.byType(IconButton));
      await t.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byTooltip('已复制'), findsOneWidget);
      expect(
        calls.map((c) => c.method),
        containsAll(['Clipboard.setData', 'HapticFeedback.vibrate']),
      );
      await t.pump(const Duration(milliseconds: 1700));
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });
}
