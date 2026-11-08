import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/completed_works.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

import 'support.dart';

MediaTask work(String id, {bool done = true}) => MediaTask(
  id: id,
  kind: 'video',
  prompt: id,
  args: {},
  status: done ? 'completed' : 'queued',
  urls: done ? ['https://example.test/$id.mp4'] : [],
);

void main() {
  late JarvisController c;

  Future<void> host(WidgetTester t, {Size size = const Size(400, 800)}) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompletedWorksPresenter(controller: c, child: const Text('聊天')),
        ),
      ),
    );
  }

  Future<void> openSheet(WidgetTester t) async {
    showGeneratedWorks(t.element(find.text('聊天')), c);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }

  testWidgets('Empty: the title is 作品 with a centred photo icon and a note', (
    t,
  ) async {
    await host(t);
    await openSheet(t);
    expect(find.text('作品'), findsOneWidget);
    expect(find.text('生成作品'), findsNothing);
    expect(find.byKey(const Key('sheet-grabber')), findsOneWidget);
    final icon = t.widget<Icon>(find.byIcon(Icons.photo_library_outlined));
    expect(icon.size, 34);
    expect(find.text('还没有作品'), findsOneWidget);
    // Centred across the sheet's width.
    expect(
      t.getCenter(find.byIcon(Icons.photo_library_outlined)).dx,
      closeTo(200, 1),
    );
    final title = t.widget<Text>(find.text('作品'));
    expect(title.style?.fontSize, 20);
    expect(title.style?.fontWeight, FontWeight.w600);
    await close(t);
  });

  testWidgets('Lists the works of every conversation, the newest first, on the '
      'container colour', (t) async {
    await host(t);
    c.current.tasks
      ..add(work('a1'))
      ..add(work('a2'));
    final older = Conversation('older');
    older.tasks.add(work('b1'));
    c.conversations.add(older);
    await openSheet(t);
    final ids = t
        .widgetList<MediaCard>(find.byType(MediaCard))
        .map((m) => m.task.id)
        .toList();
    expect(ids, ['a2', 'a1', 'b1']);
    // The sheet gives its cards the container colour (a card reads it from the
    // card theme).
    final card = t.element(find.byType(MediaCard).first);
    final theme = Theme.of(card);
    expect(theme.cardTheme.color, theme.colorScheme.surfaceContainer);
    await close(t);
  });

  testWidgets('Opens at half the window and can be drawn up to all of it', (
    t,
  ) async {
    await host(t);
    c.current.tasks.addAll([for (var i = 0; i < 6; i++) work('w$i')]);
    await openSheet(t);
    final sheet = find.byType(DraggableScrollableSheet);
    expect(t.getSize(sheet).height, 400);
    await t.drag(find.byKey(const Key('works-sheet')), const Offset(0, -400));
    await t.pumpAndSettle();
    expect(t.getSize(sheet).height, closeTo(800, 1));
    await close(t);
  });

  testWidgets('A finished work opens the sheet after a second, with a haptic '
      'and an announcement', (t) async {
    final calls = <MethodCall>[];
    final said = <Object?>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    t.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      SystemChannels.accessibility,
      (message) async {
        said.add(message);
        return null;
      },
    );
    addTearDown(() {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      t.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility,
        null,
      );
    });
    await host(t);
    c.current.tasks.add(work('fresh'));
    c.notifyDraftSuggestion();
    await t.pump(const Duration(milliseconds: 900));
    expect(find.text('作品'), findsNothing);
    expect(calls.where((m) => m.method == 'HapticFeedback.vibrate'), isEmpty);
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('作品'), findsOneWidget);
    final haptics = calls.where((m) => m.method == 'HapticFeedback.vibrate');
    expect(haptics.map((m) => m.arguments), [
      'HapticFeedbackType.mediumImpact',
    ]);
    expect(
      said.whereType<Map>().where((m) => '${m['data']}'.contains('作品已生成')),
      hasLength(1),
    );
    await close(t);
  });
}
