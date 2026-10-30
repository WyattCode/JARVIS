import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';

import 'c2_support.dart';
import 'c2_voice_test.dart' show pumpVoice;

void main() {
  group('a picker row with nothing to pick', () {
    testWidgets('says so and does not open an empty menu', (t) async {
      sizeWindow(t, const Size(402, 874), EdgeInsets.zero);
      var picked = 0;
      final semantics = t.ensureSemantics();
      await t.pumpWidget(
        appHost(
          Scaffold(
            body: PickerRow<String>(
              label: '语音引擎',
              value: null,
              options: const [],
              onSelected: (_) => picked++,
            ),
          ),
        ),
      );
      expect(find.text('暂无可选'), findsOneWidget);
      await t.tap(find.text('语音引擎'));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      expect(t.takeException(), isNull);
      expect(picked, 0);
      final node = t.getSemantics(find.bySemanticsLabel('语音引擎'));
      expect(node.flagsCollection.isEnabled, Tristate.isFalse);
      semantics.dispose();
    });
  });

  testWidgets('a new turn in a call brings the transcript back to its tail', (
    t,
  ) async {
    final c = await pumpVoice(
      t,
      size: const Size(402, 874),
      transcript: '这是很长的一段转写内容。' * 12,
    );
    final scroll = find.byKey(const Key('voice-transcript'));
    ScrollPosition position() => t
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
        )
        .position;
    await t.pump();
    await t.pump();
    expect(position().maxScrollExtent, greaterThan(0));
    expect(position().pixels, position().maxScrollExtent);
    // The user reads back.
    await t.drag(scroll, const Offset(0, 300));
    await t.pump();
    expect(position().pixels, lessThan(position().maxScrollExtent));
    // The same turn growing does not pull the view away from what is being read.
    c.voice.lastBot = '${c.voice.lastBot}更多。';
    c.notifyDraftSuggestion();
    await t.pump();
    await t.pump();
    expect(position().pixels, lessThan(position().maxScrollExtent));
    // A new question starts the next turn: follow it again.
    c.voice.lastYou = '新的问题';
    c.voice.lastBot = '新的回答。' * 120;
    c.notifyDraftSuggestion();
    await t.pump();
    await t.pump();
    expect(position().pixels, position().maxScrollExtent);
    await t.pump(const Duration(seconds: 1));
    await t.pumpWidget(const SizedBox());
  });
}
