import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/startup_scene.dart';

import 'support.dart';

class Page extends StatefulWidget {
  const Page(this.label, {super.key});
  final String label;
  @override
  State<Page> createState() => PageState();
}

class PageState extends State<Page> {
  int builds = 0;
  @override
  Widget build(BuildContext context) {
    builds++;
    return Scaffold(body: Text(widget.label));
  }
}

Future<void> land(WidgetTester t) async {
  await t.pump();
  await t.pump();
  await t.pump(const Duration(seconds: 2));
  await t.pump();
}

void main() {
  group('login <-> chat cross-fade', () {
    Widget gate(Widget child) =>
        MaterialApp(home: StartupGate(ready: true, child: child));

    testWidgets('both pages exist while fading, the outgoing one is inert', (
      t,
    ) async {
      await t.pumpWidget(gate(const Page('a', key: ValueKey('login'))));
      await land(t);
      await t.pumpWidget(gate(const Page('b', key: ValueKey('chat'))));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('a'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);
      final fades = t.widgetList<FadeTransition>(
        find.ancestor(
          of: find.text('b'),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fades.first.opacity.value, inExclusiveRange(0, 1));
      final outgoing = find.ancestor(
        of: find.text('a'),
        matching: find.byType(IgnorePointer),
      );
      expect(t.widget<IgnorePointer>(outgoing.first).ignoring, isTrue);
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('a'), findsNothing);
      expect(find.text('b'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion swaps at once', (t) async {
      t.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await t.pumpWidget(gate(const Page('a', key: ValueKey('login'))));
      await land(t);
      await t.pumpWidget(gate(const Page('b', key: ValueKey('chat'))));
      await t.pump();
      expect(find.text('a'), findsNothing);
      expect(find.text('b'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets(
      'during the launch flight a swap is immediate (no two pages with the reactor keys)',
      (t) async {
        await t.pumpWidget(gate(const Page('a', key: ValueKey('login'))));
        await t.pump();
        await t.pumpWidget(gate(const Page('b', key: ValueKey('chat'))));
        await t.pump();
        expect(find.text('a'), findsNothing);
        expect(find.text('b'), findsOneWidget);
        await t.pump(const Duration(seconds: 2));
        await t.pumpWidget(const SizedBox());
      },
    );

    testWidgets('the page takes touches before the reactor has landed', (
      t,
    ) async {
      var taps = 0;
      await t.pumpWidget(
        MaterialApp(
          home: StartupGate(
            ready: true,
            child: Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => taps++,
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.text('go'), warnIfMissed: false);
      expect(taps, 0, reason: 'still faint');
      await t.pump(const Duration(milliseconds: 560));
      await t.tap(find.text('go'), warnIfMissed: false);
      expect(taps, 1, reason: 'opaque before the 700 ms flight ends');
      await t.pump(const Duration(seconds: 1));
      await t.pumpWidget(const SizedBox());
    });
  });

  group('theme', () {
    Future<NavigatorState> pumpApp(WidgetTester t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await t.pumpWidget(JarvisApp(controller: c));
      await t.pump(const Duration(seconds: 3));
      return t.state<NavigatorState>(find.byType(Navigator).first);
    }

    testWidgets(
      'iOS has no ink splash',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (t) async {
        await pumpApp(t);
        final theme = Theme.of(t.element(find.byType(Scaffold).first));
        expect(theme.splashFactory, NoSplash.splashFactory);
        await t.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'a pushed page slides on iOS and fades when motion is reduced',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (t) async {
        final navigator = await pumpApp(t);
        Future<void> push() async {
          navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('next')),
            ),
          );
          await t.pump();
          await t.pump(const Duration(milliseconds: 100));
        }

        await push();
        expect(find.byType(CupertinoPageTransition), findsWidgets);
        navigator.pop();
        await t.pump();
        await t.pump(const Duration(seconds: 1));

        t.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
        await t.pump();
        await push();
        expect(find.byType(CupertinoPageTransition), findsNothing);
        expect(
          t
              .widget<MaterialApp>(find.byType(MaterialApp))
              .themeAnimationDuration,
          Duration.zero,
        );
        await t.pump(const Duration(seconds: 1));
        await t.pumpWidget(const SizedBox());
      },
    );
  });
}
