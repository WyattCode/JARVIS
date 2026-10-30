import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/duo_rail.dart';

/// The native strip: 48 pt buttons, 16 pt between them (none after the last one).
const extent = DuoRail.nativeExtent;
const gap = DuoRail.nativeExtent - DuoRail.nativeButton;

DuoRailAction a(String id) => DuoRailAction(
  id: id,
  icon: Icons.circle,
  symbol: 'circle',
  label: id,
  onPressed: () {},
);
List<String> ids(List<DuoRailAction> l) => [for (final x in l) x.id];

void main() {
  test('the native strip is 48 + 16 per button', () {
    expect(extent, 64);
    expect(gap, 16);
  });

  group('splitDuoRail (no keyboard)', () {
    final top = [a('t1'), a('t2')], bottom = [a('b1')];

    test('exactly n*extent - gap fits n buttons, one less point does not', () {
      final fits = splitDuoRail(
        top,
        bottom,
        3 * extent - gap,
        extent: extent,
        gap: gap,
      );
      expect(ids(fits.top), ['t1', 't2']);
      expect(ids(fits.bottom), ['b1']);
      expect(fits.overflow, isEmpty);
      final tight = splitDuoRail(
        top,
        bottom,
        3 * extent - gap - 1,
        extent: extent,
        gap: gap,
      );
      expect(tight.overflow, isNotEmpty);
      // 175 pt hold two 48 pt buttons: the menu button and one control.
      expect(ids(tight.top), ['t1']);
      expect(ids(tight.overflow), ['t2', 'b1']);
    });

    test('one slot only: just the menu; less than a button: nothing', () {
      final one = splitDuoRail(top, bottom, 48, extent: extent, gap: gap);
      expect(one.top, isEmpty);
      expect(one.bottom, isEmpty);
      expect(ids(one.overflow), ['t1', 't2', 'b1']);
      final none = splitDuoRail(top, bottom, 47.9, extent: extent, gap: gap);
      expect(none.top, isEmpty);
      expect(none.overflow, isEmpty);
    });

    test('without a gap the old arithmetic holds', () {
      final s = splitDuoRail(top, bottom, 3 * 58, extent: 58);
      expect(s.overflow, isEmpty);
      final tight = splitDuoRail(top, bottom, 3 * 58 - 1, extent: 58);
      expect(tight.overflow, isNotEmpty);
    });
  });

  group('splitDuoRailForKeyboard', () {
    test('slots == buttons: everything stacks from the top', () {
      final s = splitDuoRailForKeyboard(
        [a('t1'), a('t2')],
        [a('b1')],
        3 * extent - gap,
        extent: extent,
        gap: gap,
      );
      expect(ids(s.top), ['t1', 't2', 'b1']);
      expect(s.bottom, isEmpty);
      expect(s.overflow, isEmpty);
    });

    test('one point short of that: the bottom group goes into the menu', () {
      final s = splitDuoRailForKeyboard(
        [a('t1'), a('t2')],
        [a('b1')],
        3 * extent - gap - 1,
        extent: extent,
        gap: gap,
      );
      expect(ids(s.top), ['t1']);
      expect(ids(s.overflow), ['t2', 'b1']);
    });

    test('exactly one slot that cannot hold everything: only the menu', () {
      final s = splitDuoRailForKeyboard(
        [a('t1')],
        [a('b1')],
        48,
        extent: extent,
        gap: gap,
      );
      expect(s.top, isEmpty);
      expect(s.bottom, isEmpty);
      expect(ids(s.overflow), ['t1', 'b1']);
    });

    test('a single control on one slot still fits as itself', () {
      final s = splitDuoRailForKeyboard(
        [a('t1')],
        const [],
        48,
        extent: extent,
        gap: gap,
      );
      expect(ids(s.top), ['t1']);
      expect(s.overflow, isEmpty);
    });

    test('below one button: nothing at all', () {
      final s = splitDuoRailForKeyboard(
        [a('t1')],
        [a('b1')],
        47.9,
        extent: extent,
        gap: gap,
      );
      expect(s.top, isEmpty);
      expect(s.overflow, isEmpty);
    });

    test('empty groups: nothing', () {
      final s = splitDuoRailForKeyboard(
        const [],
        const [],
        300,
        extent: extent,
        gap: gap,
      );
      expect(s.top, isEmpty);
      expect(s.overflow, isEmpty);
    });
  });
}
