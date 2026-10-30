import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'b_chat_ui_test.dart' show halfFolded;
import 'duo_rail_test.dart' show duoLandscape;
import 'support.dart';

void main() {
  testWidgets('the login form keeps to the roomier side when half-folded', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(951, 669);
    t.view.padding = const FakeViewPadding(right: 84, bottom: 34);
    t.view.viewPadding = t.view.padding;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewPadding);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    final layout = ValueNotifier(duoLandscape);
    await t.pumpWidget(
      DuoLayoutScope(
        layout: layout,
        child: MaterialApp(home: LoginPage(controller: c)),
      ),
    );
    await t.pump(const Duration(milliseconds: 400));
    final field = find.byType(TextField).first;
    final flat = t.getRect(field);
    expect(flat.left, lessThan(455.5));

    layout.value = halfFolded;
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 500));
    final folded = t.getRect(field);
    expect(folded.left, greaterThanOrEqualTo(495.5));
    expect(folded.right, lessThanOrEqualTo(867));
    expect(t.takeException(), isNull);

    layout.value = duoLandscape;
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 500));
    expect(t.getRect(field), flat);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('on the outer display the brand row sits on the header axis', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(466, 678);
    t.view.padding = const FakeViewPadding(right: 84, bottom: 34);
    t.view.viewPadding = t.view.padding;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewPadding);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    final layout = DuoLayout.fromMap({
      'edge': 'right',
      'width': 466.0,
      'height': 678.0,
      'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
      'systemBar': {
        'cx': 418.0,
        'top': 198.0,
        'bottom': 630.0,
        'titleCY': 48.0,
      },
    });
    await t.pumpWidget(
      DuoLayoutScope(
        layout: ValueNotifier(layout),
        child: MaterialApp(home: LoginPage(controller: c)),
      ),
    );
    await t.pump(const Duration(milliseconds: 400));
    // The same line the chat header and the sidebar title use (the system's own title position).
    expect(
      t.getCenter(find.byKey(const ValueKey('login-brand-row'))).dy,
      closeTo(layout.headerAxisY, 1),
    );
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
