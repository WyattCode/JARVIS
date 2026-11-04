import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

void main() {
  testWidgets(
    'Deletion notice with Undo expires after 1.5s, including accessibility mode',
    (t) async {
      for (final accessible in [false, true]) {
        late BuildContext host;
        await t.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(accessibleNavigation: accessible),
              child: Scaffold(
                body: Builder(
                  builder: (context) {
                    host = context;
                    return const SizedBox();
                  },
                ),
              ),
            ),
          ),
        );
        showNotice(
          host,
          '会话已删除',
          compact: true,
          duration: const Duration(milliseconds: 1500),
          action: SnackBarAction(label: '撤销', onPressed: () {}),
        );
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('会话已删除'), findsOneWidget);
        await t.pump(const Duration(milliseconds: 1600));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('会话已删除'), findsNothing);
        await t.pumpWidget(const SizedBox());
      }
    },
  );
}
