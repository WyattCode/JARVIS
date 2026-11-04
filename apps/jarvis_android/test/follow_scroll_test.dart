import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/follow_scroll.dart';

void main() {
  testWidgets('The newest message is visible in the first painted frame', (
    t,
  ) async {
    final scroll = FollowScrollController();
    await t.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 300,
          child: scroll.wrap(
            ListView.builder(
              controller: scroll,
              itemExtent: 80,
              itemCount: 40,
              itemBuilder: (_, i) => Text('message $i'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('message 39'), findsOneWidget);
    final tail = t.getRect(find.text('message 39'));
    expect(tail.top, lessThan(t.view.physicalSize.height));
    final firstOffset = scroll.offset;
    await t.pump();
    expect(scroll.offset, closeTo(firstOffset, .01));
    await t.pumpWidget(const SizedBox());
    scroll.dispose();
  });
  testWidgets(
    'Async media growth follows the tail and preserves an intentional upward scroll',
    (t) async {
      final scroll = FollowScrollController();
      final height = ValueNotifier<double>(120);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: scroll.wrap(
                SingleChildScrollView(
                  controller: scroll,
                  child: Column(
                    children: [
                      const SizedBox(
                        height: 500,
                        child: Text('Earlier message'),
                      ),
                      ValueListenableBuilder<double>(
                        valueListenable: height,
                        builder: (_, value, _) =>
                            SizedBox(height: value, child: const Text('Image')),
                      ),
                      const SizedBox(
                        height: 48,
                        child: Text('Latest controls'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      scroll.followLatest();
      await t.pump();
      await t.pump();
      expect(scroll.position.extentAfter, closeTo(0, .01));
      // The image changes its own layout without notifying the chat controller.
      height.value = 900;
      await t.pump();
      await t.pump();
      await t.pump();
      expect(scroll.position.extentAfter, closeTo(0, .01));
      await t.drag(find.byType(SingleChildScrollView), const Offset(0, 180));
      await t.pumpAndSettle();
      final readingOffset = scroll.offset;
      expect(scroll.position.extentAfter, greaterThan(64));
      height.value = 1200;
      scroll.followLatest();
      await t.pump();
      await t.pump();
      expect(scroll.offset, closeTo(readingOffset, .01));
      // Deliberately return to the end, then the next image can grow and follow.
      await t.drag(find.byType(SingleChildScrollView), const Offset(0, -2000));
      await t.pumpAndSettle();
      height.value = 1500;
      await t.pump();
      await t.pump();
      await t.pump();
      expect(scroll.position.extentAfter, closeTo(0, .01));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      scroll.dispose();
      height.dispose();
    },
  );
}
