import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/keyboard_dismiss.dart';

Widget app() => MaterialApp(
  home: Scaffold(
    body: Column(
      children: [
        TextField(
          key: const Key('field'),
          onTapOutside: dismissKeyboardOnTapOutside,
        ),
        const Spacer(),
        TextButton(
          key: const Key('btn'),
          onPressed: () {},
          child: const Text('other'),
        ),
      ],
    ),
  ),
);

bool editing() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>() !=
    null;

void main() {
  testWidgets(
    'iOS: tapping elsewhere hides the keyboard, tapping again shows it',
    (t) async {
      await t.pumpWidget(app());
      await t.tap(find.byKey(const Key('field')));
      await t.pump();
      expect(editing(), isTrue);
      await t.tap(find.byKey(const Key('btn')));
      await t.pump();
      expect(editing(), isFalse);
      await t.tap(find.byKey(const Key('field')));
      await t.pump();
      expect(editing(), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('Android: tapping elsewhere leaves the focus alone', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('field')));
    await t.pump();
    await t.tap(find.byKey(const Key('btn')));
    await t.pump();
    expect(editing(), isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
