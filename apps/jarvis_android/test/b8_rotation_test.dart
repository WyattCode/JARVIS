import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/rotation_dissolve.dart';

Widget app(Size size, {bool reduceMotion = false}) => MediaQuery(
  data: MediaQueryData(size: size, disableAnimations: reduceMotion),
  child: const Directionality(
    textDirection: TextDirection.ltr,
    child: RotationDissolve(child: SizedBox.expand(key: Key('content'))),
  ),
);

double opacity(WidgetTester t) {
  final finder = find.ancestor(
    of: find.byKey(const Key('content')),
    matching: find.byType(Opacity),
  );
  return finder.evaluate().isEmpty ? 1 : t.widget<Opacity>(finder).opacity;
}

void main() {
  test('only a turn between portrait and landscape counts', () {
    expect(
      RotationDissolve.turned(const Size(400, 800), const Size(800, 400)),
      isTrue,
    );
    expect(
      RotationDissolve.turned(const Size(400, 800), const Size(400, 500)),
      isFalse,
    );
    expect(
      RotationDissolve.turned(const Size(466, 678), const Size(951, 669)),
      isTrue,
    );
  });

  testWidgets('turning the phone dissolves the new layout in', (t) async {
    await t.pumpWidget(app(const Size(400, 800)));
    expect(opacity(t), 1, reason: 'the first layout is simply there');
    await t.pumpWidget(app(const Size(800, 400)));
    expect(opacity(t), 0);
    await t.pump(const Duration(milliseconds: 130));
    expect(opacity(t), inExclusiveRange(0, 1));
    await t.pump(const Duration(milliseconds: 200));
    expect(opacity(t), 1);
  });

  testWidgets('the keyboard coming up does not', (t) async {
    await t.pumpWidget(app(const Size(400, 800)));
    await t.pumpWidget(app(const Size(400, 500)));
    expect(opacity(t), 1);
  });

  testWidgets('reduced motion: no dissolve', (t) async {
    await t.pumpWidget(app(const Size(400, 800), reduceMotion: true));
    await t.pumpWidget(app(const Size(800, 400), reduceMotion: true));
    expect(opacity(t), 1);
  });

  testWidgets('while it dissolves in, the app\'s own background is under it', (
    t,
  ) async {
    const background = Color(0xFF09090B);
    Widget themed(Size size) => MediaQuery(
      data: MediaQueryData(size: size),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: ThemeData(scaffoldBackgroundColor: background),
          child: const RotationDissolve(
            child: SizedBox.expand(key: Key('content')),
          ),
        ),
      ),
    );
    await t.pumpWidget(themed(const Size(400, 800)));
    await t.pumpWidget(themed(const Size(800, 400)));
    await t.pump(const Duration(milliseconds: 60));
    final under = find.ancestor(
      of: find.byType(Opacity),
      matching: find.byType(ColoredBox),
    );
    expect(under, findsOneWidget);
    expect(t.widget<ColoredBox>(under).color, background);
    await t.pump(const Duration(milliseconds: 300));
  });
}
