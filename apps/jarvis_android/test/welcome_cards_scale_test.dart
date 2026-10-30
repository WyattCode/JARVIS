import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/starters.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'duo_rail_test.dart' show duoLandscape, duoOuter, pumpHome;

/// The outer display of the Duo on its side: the strip stays on the right.
final duoOuterSideways = DuoLayout.fromMap({
  'edge': 'right',
  'width': 678.0,
  'height': 466.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
  'regions': [],
});

final _poses = <String, (DuoLayout, Size, EdgeInsets?)>{
  'Duo outer 466x678': (duoOuter, const Size(466, 678), null),
  'Duo outer 678x466': (duoOuterSideways, const Size(678, 466), null),
  'Duo inner 951x669': (duoLandscape, const Size(951, 669), null),
  'phone 375x667': (
    DuoLayout.none,
    const Size(375, 667),
    const EdgeInsets.only(top: 20),
  ),
  'phone 402x874': (
    DuoLayout.none,
    const Size(402, 874),
    const EdgeInsets.only(top: 62, bottom: 34),
  ),
  'phone 844x390': (
    DuoLayout.none,
    const Size(844, 390),
    const EdgeInsets.only(left: 47, right: 47, bottom: 21),
  ),
};

/// Shown: laid out with some height and not faded out.
bool _shown(WidgetTester t, Finder f) =>
    f.evaluate().isNotEmpty &&
    t.getSize(f.first).height > 1 &&
    !find
        .ancestor(of: f, matching: find.byType(Opacity))
        .evaluate()
        .any((e) => (e.widget as Opacity).opacity < .5);

Future<void> _pump(
  WidgetTester t,
  (DuoLayout, Size, EdgeInsets?) pose,
  double scale,
) async {
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  await pumpHome(t, pose.$1, size: pose.$2, insets: pose.$3);
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  // The cards come before the avatar: it shrinks and goes (and the hint with it) first, and if the four cards still do
  // not fit the page scrolls rather than dropping them.
  for (final MapEntry(key: name, value: pose) in _poses.entries) {
    for (final scale in [1.0, 1.35, 2.0, 2.4]) {
      testWidgets('all four welcome cards are there on $name x$scale', (
        t,
      ) async {
        await _pump(t, pose, scale);
        for (var i = 0; i < 4; i++) {
          final card = find.byKey(ValueKey('starter-$i'));
          expect(_shown(t, card), isTrue, reason: 'card $i');
          // Each one can be scrolled whole into view.
          final scrollable = find
              .ancestor(of: card, matching: find.byType(Scrollable))
              .first;
          final page = t.getRect(scrollable);
          final extent = t
              .state<ScrollableState>(scrollable)
              .position
              .maxScrollExtent;
          final rect = t.getRect(card);
          expect(rect.height, lessThanOrEqualTo(page.height + .5));
          expect(rect.top, greaterThanOrEqualTo(page.top - .5));
          expect(rect.bottom, lessThanOrEqualTo(page.bottom + extent + .5));
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      });
    }

    testWidgets(
      'the welcome avatar only ever shrinks as the text grows on $name',
      (t) async {
        final sizes = <double>[];
        for (var scale = 1.0; scale <= 2.401; scale += .04) {
          await _pump(t, pose, scale);
          final avatar = find.byType(CoreAvatar);
          sizes.add(_shown(t, avatar) ? t.getSize(avatar).width : 0);
          await t.pumpWidget(const SizedBox());
        }
        for (var i = 1; i < sizes.length; i++) {
          expect(
            sizes[i],
            lessThanOrEqualTo(sizes[i - 1] + .01),
            reason: 'x${(1 + .04 * i).toStringAsFixed(2)}: $sizes',
          );
        }
      },
    );
  }

  // Which four starters a session draws is random; what fits must not depend on it. Each run draws again.
  for (final MapEntry(key: name, value: pose) in {
    'Duo outer 466x678': _poses['Duo outer 466x678']!,
    'Duo inner 951x669': _poses['Duo inner 951x669']!,
  }.entries) {
    for (final scale in [1.12, 1.24, 1.28, 1.35]) {
      testWidgets(
        'the welcome avatar does not depend on the cards drawn ($name x$scale)',
        (t) async {
          final sizes = <double>{};
          for (var run = 0; run < 6; run++) {
            await _pump(t, pose, scale);
            final avatar = find.byType(CoreAvatar);
            sizes.add(_shown(t, avatar) ? t.getSize(avatar).width : 0);
            await t.pumpWidget(const SizedBox());
          }
          expect(sizes, hasLength(1));
        },
      );
    }
  }

  testWidgets('a wrapped card description never leaves one character alone', (
    t,
  ) async {
    const text = '保留你的意思，表达更清楚';
    final starter = starterGroups
        .expand((g) => g)
        .firstWhere((s) => s.description == text);
    // Wide enough for 11 of the 12 characters on the first line: unattended, "楚" would sit alone on the second.
    for (final width in [24 + 11 * 12.0 + 4, 24 + 10 * 12.0 + 6]) {
      await t.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: width,
              height: 120,
              child: WebStarterCard(
                starter: starter,
                compact: true,
                descriptionLines: 2,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      final paragraph = t.renderObject<RenderParagraph>(find.text(text));
      double lineOf(int offset) => paragraph
          .getOffsetForCaret(TextPosition(offset: offset), Rect.zero)
          .dy;
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(
        lineOf(text.length - 1),
        greaterThan(lineOf(0)),
        reason: 'it does wrap at $width',
      );
      expect(
        lineOf(text.length - 2),
        lineOf(text.length - 1),
        reason: 'the last two characters share the last line at $width',
      );
    }
  });
}
