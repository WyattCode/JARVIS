import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/duo_rail.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'duo_rail_test.dart' show duoOuter;
import 'support.dart';

/// What the one native strip was made with and told since.
class _Native {
  final created = <Map<Object?, Object?>>[];
  final calls = <MethodCall>[];
  int? id;

  /// The ids the strip shows now (creation params, then the latest update).
  List<String> get ids {
    Map<Object?, Object?>? params;
    for (final c in calls.reversed) {
      if (c.method == 'update') {
        params = c.arguments as Map<Object?, Object?>;
        break;
      }
    }
    params ??= created.last;
    return [
      for (final group in ['top', 'bottom', 'overflow'])
        for (final item in params[group] as List<Object?>)
          (item as Map<Object?, Object?>)['id'] as String,
    ];
  }
}

Future<_Native> _mockNative(WidgetTester t) async {
  final native = _Native();
  final messenger = t.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
    call,
  ) async {
    if (call.method == 'create') {
      final args = call.arguments as Map<Object?, Object?>;
      final bytes = args['params'] as Uint8List;
      native.created.add(
        const StandardMessageCodec().decodeMessage(ByteData.sublistView(bytes))
            as Map<Object?, Object?>,
      );
      final id = native.id = args['id'] as int;
      messenger.setMockMethodCallHandler(
        MethodChannel('ai.jarvis.app/duo-rail/$id'),
        (c) async {
          native.calls.add(c);
          return null;
        },
      );
    }
    return null;
  });
  addTearDown(
    () =>
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null),
  );
  return native;
}

/// A tap on a button of the native strip, as the native view reports it.
Future<void> _tapNative(WidgetTester t, _Native native, String id) async {
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
    'ai.jarvis.app/duo-rail/${native.id}',
    const StandardMethodCodec().encodeMethodCall(MethodCall('tap', id)),
    (_) {},
  );
}

DuoRailAction _action(String id, VoidCallback onPressed) => DuoRailAction(
  id: id,
  icon: Icons.circle,
  symbol: 'circle',
  label: id,
  onPressed: onPressed,
);

Future<void> _pumpApp(WidgetTester t, Widget home) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(466, 678);
  t.view.padding = const FakeViewPadding(right: 84, bottom: 34);
  t.view.viewPadding = t.view.padding;
  addTearDown(t.view.reset);
  final routes = DuoRailRoutes();
  addTearDown(routes.dispose);
  await t.pumpWidget(
    DuoLayoutScope(
      layout: ValueNotifier(duoOuter),
      child: MaterialApp(
        navigatorObservers: [routes],
        builder: (context, child) => DuoRailHost(routes: routes, child: child!),
        home: home,
      ),
    ),
  );
  await t.pump();
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  int pressed = 0;
  int generation = 0;

  void nextGeneration() => setState(() => generation++);

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(child: Scaffold(body: SizedBox())),
      DuoRail(
        top: [
          // A new closure every build: a tap must reach the latest one.
          _action('menu', () => pressed += 1 + generation * 100),
        ],
        bottom: [_action('settings', () {})],
      ),
    ],
  );
}

Widget _railPage(BuildContext context) => DuoRailPage(
  top: [DuoRailPage.back(context)],
  child: const Scaffold(body: SizedBox()),
);

/// Runs [body] as on iOS, where the strip is the native view.
void _iosTest(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await body(t);
        await t.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

void main() {
  _iosTest(
    'a pushed page changes the buttons of the one strip; nothing slides or is made again',
    (t) async {
      final native = await _mockNative(t);
      await _pumpApp(t, const _Home());
      expect(native.created, hasLength(1));
      expect(native.ids, ['menu', 'settings']);
      final rest = t.getRect(find.byType(UiKitView));

      final navigator = t.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute<void>(builder: _railPage));
      for (var frame = 0; frame < 30; frame++) {
        await t.pump(const Duration(milliseconds: 16));
        expect(
          find.byType(UiKitView, skipOffstage: false),
          findsOneWidget,
          reason: 'frame $frame: one native strip only',
        );
        expect(
          t.getRect(find.byType(UiKitView)),
          rest,
          reason: 'frame $frame: the strip stays where it is',
        );
        if (frame >= 1) {
          expect(native.ids, ['back'], reason: 'frame $frame');
        }
      }
      expect(native.created, hasLength(1), reason: 'never made again');

      // Popping hands the strip back at once, not when the page has slid away.
      navigator.pop();
      await t.pump();
      await t.pump(const Duration(milliseconds: 16));
      expect(native.ids, ['menu', 'settings']);
      await t.pump(const Duration(milliseconds: 600));
      expect(native.created, hasLength(1));
      expect(t.getRect(find.byType(UiKitView)), rest);
    },
  );

  _iosTest(
    'the strip switches before a push or a pop has put a frame on screen',
    (t) async {
      final native = await _mockNative(t);
      await _pumpApp(t, const _Home());
      final navigator = t.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute<void>(builder: _railPage));
      // The push's first frame lays the page out offstage: nothing has moved on screen yet.
      await t.pump();
      expect(find.byType(DuoRailPage), findsNothing);
      expect(find.byType(DuoRailPage, skipOffstage: false), findsOneWidget);
      expect(native.ids, ['back'], reason: 'switched right after that frame');

      await t.pump(const Duration(milliseconds: 600));
      navigator.pop();
      expect(native.ids, [
        'menu',
        'settings',
      ], reason: 'before the pop\'s first frame');
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(native.created, hasLength(1));
    },
  );

  _iosTest('a tap reaches the page\'s latest closure', (t) async {
    final native = await _mockNative(t);
    await _pumpApp(t, const _Home());
    final home = t.state<_HomeState>(find.byType(_Home));
    home.nextGeneration();
    await t.pump();
    await _tapNative(t, native, 'menu');
    expect(home.pressed, 101);
  });

  _iosTest(
    'a dialog shades the strip and keeps it from being pressed, until it has faded out',
    (t) async {
      await _mockNative(t);
      await _pumpApp(t, const _Home());
      bool ignoring() => t
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byType(UiKitView),
                  matching: find.byType(IgnorePointer),
                )
                .last,
          )
          .ignoring;
      Finder shade() => find.descendant(
        of: find.byKey(const Key('duo-rail')),
        matching: find.byType(ColoredBox),
      );
      expect(ignoring(), isFalse);
      expect(shade(), findsNothing);

      final context = t.element(find.byType(_Home));
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('x')),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(ignoring(), isTrue);
      expect(shade(), findsOneWidget);
      expect(
        t.widget<ColoredBox>(shade()).color.a,
        greaterThan(.3),
        reason: 'the barrier\'s shade',
      );

      Navigator.of(context).pop();
      await t.pump();
      await t.pump(const Duration(milliseconds: 16));
      expect(ignoring(), isFalse, reason: 'pressable again at once');
      expect(
        shade(),
        findsOneWidget,
        reason: 'the shade fades with the barrier',
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pump();
      expect(shade(), findsNothing);
    },
  );

  _iosTest('a page without controls takes the strip away; back brings it', (
    t,
  ) async {
    await _mockNative(t);
    await _pumpApp(t, const _Home());
    final navigator = t.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('preview')),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.byType(UiKitView), findsNothing);
    navigator.pop();
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.byType(UiKitView), findsOneWidget);
  });

  _iosTest(
    'the app: opening settings keeps the strip and swaps in its back button',
    (t) async {
      final native = await _mockNative(t);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await _pumpApp(t, JarvisHome(controller: c));
      await t.pump(const Duration(seconds: 1));
      expect(native.ids, containsAll(['sidebar', 'new-chat', 'settings']));
      final rest = t.getRect(find.byType(UiKitView));

      await _tapNative(t, native, 'settings');
      for (var frame = 0; frame < 30; frame++) {
        await t.pump(const Duration(milliseconds: 16));
        expect(find.byType(UiKitView, skipOffstage: false), findsOneWidget);
        expect(t.getRect(find.byType(UiKitView)), rest);
      }
      expect(native.ids, ['back']);
      expect(native.created, hasLength(1));
      expect(find.byKey(const Key('settings-scroll')), findsOneWidget);

      await _tapNative(t, native, 'back');
      await t.pump();
      await t.pump(const Duration(milliseconds: 16));
      expect(native.ids, containsAll(['sidebar', 'new-chat', 'settings']));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('settings-scroll')), findsNothing);
    },
  );
}
