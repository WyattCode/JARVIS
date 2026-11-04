import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/motion.dart';

void main() {
  Widget host({required bool reduce, required bool tall}) => MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          SmoothSize(child: SizedBox(height: tall ? 80 : 20, width: 100)),
        ],
      ),
    ),
  );

  testWidgets('SmoothSize grows over time normally', (t) async {
    await t.pumpWidget(host(reduce: false, tall: false));
    await t.pumpWidget(host(reduce: false, tall: true));
    await t.pump(const Duration(milliseconds: 60));
    final mid = t.getSize(find.byType(SmoothSize)).height;
    expect(mid, greaterThan(20));
    expect(mid, lessThan(80));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.getSize(find.byType(SmoothSize)).height, 80);
  });

  testWidgets('with Reduce Motion it resizes at once and does not throw', (
    t,
  ) async {
    await t.pumpWidget(host(reduce: true, tall: false));
    await t.pumpWidget(host(reduce: true, tall: true));
    expect(t.getSize(find.byType(SmoothSize)).height, 80);
    expect(t.takeException(), isNull);
  });
}
