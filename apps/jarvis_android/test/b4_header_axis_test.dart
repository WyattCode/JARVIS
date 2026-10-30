import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/duo_layout.dart';

import 'duo_rail_test.dart' show duoOuter, pumpHome;

const _method = MethodChannel('ai.jarvis.app/duo');
const _events = EventChannel('ai.jarvis.app/duo-events');

Map<String, Object?> report({required bool systemBar}) => {
  'edge': 'right',
  'width': 466.0,
  'height': 678.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
  if (systemBar)
    'systemBar': {'cx': 418.0, 'top': 198.0, 'bottom': 630.0, 'titleCY': 48.0},
};

void main() {
  test('the header axis is where the system puts a navigation title', () {
    final measured = DuoLayout.fromMap(report(systemBar: true));
    expect(measured.systemBar?.titleCenterY, 48);
    expect(measured.headerAxisY, 48);
    expect(measured.headerShiftY, 48 - 28);
    // Not reported (older shell, no probe yet): the fixed default.
    final plain = DuoLayout.fromMap(report(systemBar: false));
    expect(plain.headerAxisY, DuoLayout.headerAxis);
    expect(plain.headerShiftY, DuoLayout.headerShift);
  });

  test('the title is measured from the top of the safe area', () {
    final layout = DuoLayout.fromMap({
      ...report(systemBar: true),
      'safe': {'left': 0.0, 'top': 20.0, 'right': 84.0, 'bottom': 34.0},
    });
    expect(layout.headerAxisY, 28);
  });

  testWidgets('a late snapshot reply does not erase the measured system bar', (
    t,
  ) async {
    final reply = Completer<Object?>();
    MockStreamHandlerEventSink? sink;
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_method, (call) => reply.future);
    messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        onListen: (_, events) {
          sink = events;
        },
      ),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(_method, null);
      messenger.setMockStreamHandler(_events, null);
    });
    final source = ChannelDuoLayoutSource();
    await t.pump();
    sink!.success(report(systemBar: true));
    await t.pump();
    expect(source.value.systemBar, isNotNull);
    // The reply to the first snapshot request was taken before the bar was measured.
    reply.complete(report(systemBar: false));
    await t.pump();
    expect(source.value.systemBar, isNotNull);
    source.dispose();
  });

  testWidgets('the chat header title sits on the measured axis', (t) async {
    final measured = DuoLayout.fromMap(report(systemBar: true));
    await pumpHome(t, measured, size: const Size(466, 678));
    final title = t.getCenter(find.text('新建会话').first);
    expect(title.dy, closeTo(48, 1));
    expect(
      duoOuter.systemBar,
      isNull,
      reason: 'the fixture has no title metric',
    );
  });
}
