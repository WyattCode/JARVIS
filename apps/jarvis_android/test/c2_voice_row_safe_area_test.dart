import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';

void main() {
  testWidgets('a voice row ignores the side safe area inside its card', (
    t,
  ) async {
    Future<double> nameLeft(EdgeInsets padding) async {
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(padding: padding),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: VoiceChoiceRow(
                    name: 'Atlas',
                    description: '',
                    selected: true,
                    playing: false,
                    onSelect: () {},
                    onPlay: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return t.getTopLeft(find.text('Atlas')).dx;
    }

    final flat = await nameLeft(EdgeInsets.zero);
    final landscape = await nameLeft(
      const EdgeInsets.only(left: 62, right: 62),
    );
    expect(landscape, flat);
  });
}
