import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

Widget host(JarvisController c) => MaterialApp(
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('zh')],
  locale: const Locale('zh'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: JarvisHome(controller: c),
);
void main() {
  loginLayoutTests();
  testWidgets('Fold, rotate and keyboard changes preserve draft and session', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetViewInsets);
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewPadding);
    t.view.padding = const FakeViewPadding(top: 24, bottom: 24, right: 32);
    t.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24, right: 32);
    final api = FakeApi();
    final state = JarvisController(api, MemoryVault());
    await state.initialize();
    await state.login('Wyatt', 'test');
    final id = state.current.id;
    for (final size in [
      const Size(425, 623),
      const Size(623, 425),
      const Size(608, 860),
      const Size(860, 608),
    ]) {
      t.view.physicalSize = size;
      await t.pumpWidget(host(state));
      await t.pump();
      if (size.width == 425) {
        await t.enterText(find.byKey(const Key('chat-input')), '折叠切换保留这段草稿');
      }
      expect(state.current.id, id);
      expect(find.text('折叠切换保留这段草稿'), findsOneWidget);
      expect(t.takeException(), isNull);
      expect(
        t.getRect(find.byType(Composer)).bottom -
            t.getRect(find.byKey(const Key('composer-frame'))).bottom,
        closeTo(4, .01),
      );
      final newChat = find.byKey(const Key('new-conversation'));
      expect(newChat.hitTestable().evaluate().isNotEmpty, size.width == 860);
      if (size.width == 860) {
        final grip = t.getRect(find.byKey(const Key('pane-grip-thumb')));
        expect(grip.height, 44);
        expect(grip.center.dy, closeTo(size.height / 2, 1));
        expect(find.byType(VerticalDivider), findsNothing);
      }
      t.view.viewInsets = const FakeViewPadding(bottom: 250);
      await t.pump();
      expect(t.takeException(), isNull);
      final input = t.getRect(find.byKey(const Key('chat-input')));
      expect(input.bottom, lessThanOrEqualTo(size.height - 250));
      expect(
        t.getRect(find.byType(Composer)).bottom -
            t.getRect(find.byKey(const Key('composer-frame'))).bottom,
        closeTo(size.height - 250 < 220 ? 2 : 10, .01),
      );
      final outer = t.getRect(find.byType(Composer));
      final frame = t.getRect(find.byKey(const Key('composer-frame')));
      final bottomSpace = outer.bottom - frame.bottom;
      final pane = outer.width;
      // The keyboard is up here: a foldable's box is 17 in from each side (not
      // 32), and the upright inner display's narrowing is gone.
      final sideSpace = size.width >= 600 && size.height > size.width
          ? (pane - (pane - 17)) / 2
          : size.width == 425
          ? 8.5
          : size.width == 860
          ? (pane - (pane - 17) * .9215) / 2
          : size.width == 623
          ? (pane - (size.height - 32 - 17) * size.width / size.height * .9) / 2
          : bottomSpace;
      expect(frame.left - outer.left, closeTo(sideSpace, .01));
      expect(outer.right - frame.right, closeTo(sideSpace, .01));
      expect(newChat.hitTestable().evaluate().isNotEmpty, size.width == 860);
      t.view.viewInsets = FakeViewPadding.zero;
      await t.pump();
      expect(t.takeException(), isNull);
    }
    await t.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets('Outer screen drawer and large font remain usable', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(360, 600);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await c.login('Wyatt', 'test');
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh')],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: const TextScaler.linear(1.5),
          ),
          child: child!,
        ),
        home: JarvisHome(controller: c),
      ),
    );
    await t.pump();
    expect(t.takeException(), isNull);
    await t.tap(find.byTooltip('展开会话'));
    await t.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('sidebar-brand-row')).hitTestable(),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}

// Login has to remain scrollable with a keyboard on either display.
void loginLayoutTests() {
  testWidgets('Login form remains reachable in short keyboard windows', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetViewInsets);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    for (final size in [
      const Size(425, 623),
      const Size(623, 425),
      const Size(608, 860),
      const Size(860, 608),
    ]) {
      t.view.physicalSize = size;
      t.view.viewInsets = const FakeViewPadding(bottom: 250);
      await t.pumpWidget(
        MaterialApp(
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('zh')],
          locale: const Locale('zh'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: LoginPage(controller: c),
        ),
      );
      await t.pump();
      await t.ensureVisible(find.byType(FilledButton));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(
        t.getRect(find.byType(FilledButton)).bottom,
        lessThanOrEqualTo(size.height - 250),
      );
    }
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
