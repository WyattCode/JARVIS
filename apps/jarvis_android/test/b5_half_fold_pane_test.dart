import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/half_fold_pane.dart';

import 'b_chat_ui_test.dart' show halfFolded;
import 'duo_rail_test.dart' show duoLandscape;

void main() {
  const content = Key('content');
  Future<ValueNotifier<DuoLayout>> mount(
    WidgetTester t,
    DuoLayout start,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(951, 669);
    t.view.padding = const FakeViewPadding(right: 84, bottom: 34);
    t.view.viewPadding = t.view.padding;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewPadding);
    final layout = ValueNotifier(start);
    await t.pumpWidget(
      DuoLayoutScope(
        layout: layout,
        child: const MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: HalfFoldPane(child: SizedBox.expand(key: content)),
            ),
          ),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 50));
    return layout;
  }

  testWidgets('flat it passes the whole safe area through', (t) async {
    await mount(t, duoLandscape);
    expect(t.getRect(find.byKey(content)), const Rect.fromLTRB(0, 0, 867, 635));
    expect(
      t.widget<Opacity>(find.byKey(const Key('half-fold-fade'))).opacity,
      1,
    );
  });

  testWidgets('half-folded the content keeps right of the crease', (t) async {
    await mount(t, halfFolded);
    final rect = t.getRect(find.byKey(content));
    expect(rect.left, 495.5);
    expect(rect.right, 867);
  });

  testWidgets('folding and unfolding fades through the switch, never snaps', (
    t,
  ) async {
    final layout = await mount(t, duoLandscape);
    double fade() =>
        t.widget<Opacity>(find.byKey(const Key('half-fold-fade'))).opacity;
    Future<void> run(DuoLayout to) async {
      layout.value = to;
      await t.pump();
      await t.pump(const Duration(milliseconds: 16));
      await t.pump(const Duration(milliseconds: 150));
      expect(fade(), lessThan(.3), reason: 'dips while the layout switches');
      await t.pump(const Duration(milliseconds: 400));
      expect(fade(), 1);
    }

    await run(halfFolded);
    expect(t.getRect(find.byKey(content)).left, 495.5);
    await run(duoLandscape);
    expect(t.getRect(find.byKey(content)).left, 0);
  });
}
