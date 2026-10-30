import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/duo_layout.dart';

const _method = MethodChannel('ai.jarvis.app/duo');
const _events = EventChannel('ai.jarvis.app/duo-events');

/// A plain phone: no vertical bar, a Dynamic Island occlusion on top.
Map<String, Object?> straightPhone() => {
  'edge': 'none',
  'width': 440.0,
  'height': 956.0,
  'safe': {'left': 0.0, 'top': 62.0, 'right': 0.0, 'bottom': 34.0},
  'regions': [
    {
      'kind': 'occlusion',
      'active': true,
      'x': 140.0,
      'y': 0.0,
      'w': 160.0,
      'h': 62.0,
    },
  ],
};

Map<String, Object?> duoBar({bool systemBar = true}) => {
  'edge': 'right',
  'width': 951.0,
  'height': 669.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
  if (systemBar) 'systemBar': {'cx': 909.0, 'top': 148.0, 'bottom': 620.0},
};

void main() {
  late MockStreamHandlerEventSink? sink;
  var snapshots = 0;
  Object? snapshotReply;

  void mockChannels(WidgetTester t, {Object? snapshot}) {
    sink = null;
    snapshots = 0;
    snapshotReply = snapshot;
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_method, (call) async {
      if (call.method == 'snapshot') snapshots++;
      return snapshotReply;
    });
    messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        onListen: (_, events) {
          sink = events;
        },
        onCancel: (_) {
          sink = null;
        },
      ),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(_method, null);
      messenger.setMockStreamHandler(_events, null);
    });
  }

  testWidgets('a straight iPhone is resolved by the first report, at once', (
    t,
  ) async {
    mockChannels(t, snapshot: straightPhone());
    final source = ChannelDuoLayoutSource();
    expect(source.resolved.value, isFalse);
    await t.pump();
    expect(snapshots, 1);
    expect(
      source.resolved.value,
      isTrue,
      reason: 'no bar: nothing more to wait for',
    );
    expect(source.value.edge, DuoBarEdge.none);
    expect(source.value.hasVerticalBar, isFalse);
    expect(source.value.isFoldable, isFalse);
    expect(source.value.size, const Size(440, 956));
    source.dispose();
  });

  testWidgets('an event resolves the layout', (t) async {
    mockChannels(t);
    final source = ChannelDuoLayoutSource();
    await t.pump();
    expect(source.resolved.value, isFalse);
    sink!.success(straightPhone());
    await t.pump();
    expect(source.resolved.value, isTrue);
    expect(source.value.safe.top, 62);
    source.dispose();
  });

  testWidgets(
    'a vertical bar without the measured system bar waits for the fallback',
    (t) async {
      mockChannels(t);
      final source = ChannelDuoLayoutSource();
      await t.pump();
      sink!.success(duoBar(systemBar: false));
      await t.pump(const Duration(milliseconds: 100));
      expect(source.value.hasVerticalBar, isTrue);
      expect(source.value.systemBar, isNull);
      expect(
        source.resolved.value,
        isFalse,
        reason: 'rail metrics still unknown',
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(source.resolved.value, isFalse);
      await t.pump(const Duration(milliseconds: 150));
      expect(source.resolved.value, isTrue, reason: '700 ms fallback');
      source.dispose();
    },
  );

  testWidgets('the measured system bar resolves a vertical bar immediately', (
    t,
  ) async {
    mockChannels(t);
    final source = ChannelDuoLayoutSource();
    await t.pump();
    sink!.success(duoBar(systemBar: false));
    await t.pump(const Duration(milliseconds: 50));
    expect(source.resolved.value, isFalse);
    sink!.success(duoBar());
    await t.pump(const Duration(milliseconds: 50));
    expect(source.resolved.value, isTrue);
    expect(source.value.systemBar, isNotNull);
    source.dispose();
  });

  testWidgets('a report without a size does not resolve the layout', (t) async {
    mockChannels(t, snapshot: {'edge': 'none', 'reduceTransparency': true});
    final source = ChannelDuoLayoutSource();
    await t.pump();
    expect(source.value.reduceTransparency, isTrue);
    expect(
      source.resolved.value,
      isFalse,
      reason: 'no Flutter view yet on the native side',
    );
    source.dispose();
  });

  testWidgets('a malformed report is ignored and the last layout is kept', (
    t,
  ) async {
    mockChannels(t, snapshot: straightPhone());
    final source = ChannelDuoLayoutSource();
    await t.pump();
    final good = source.value;
    sink!.success({'edge': 'right', 'width': 'wide', 'safe': 3});
    sink!.success({
      'edge': 'right',
      'width': 951.0,
      'height': 669.0,
      'regions': [
        {'kind': 'division', 'x': 'nope'},
      ],
    });
    await t.pump();
    expect(t.takeException(), isNull, reason: 'no unhandled zone error');
    expect(source.value, good);
    sink!.success(duoBar());
    await t.pump();
    expect(
      source.value.edge,
      DuoBarEdge.right,
      reason: 'later good reports still apply',
    );
    source.dispose();
  });

  testWidgets('nothing changes after dispose', (t) async {
    mockChannels(t, snapshot: straightPhone());
    final source = ChannelDuoLayoutSource();
    await t.pump();
    final before = source.value;
    var notified = 0;
    source.addListener(() => notified++);
    final live = sink!;
    source.dispose();
    await t.pump();
    expect(sink, isNull, reason: 'the stream subscription is cancelled');
    live.success(duoBar());
    await t.pump(const Duration(seconds: 1));
    expect(notified, 0);
    expect(source.value, before);
    expect(t.takeException(), isNull);
  });

  testWidgets('an old native shell never answers: the fallback resolves it', (
    t,
  ) async {
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_method, null);
    messenger.setMockStreamHandler(_events, null);
    final source = ChannelDuoLayoutSource();
    await t.pump(const Duration(milliseconds: 650));
    expect(source.resolved.value, isFalse);
    await t.pump(const Duration(milliseconds: 100));
    expect(source.resolved.value, isTrue);
    expect(source.value, DuoLayout.none);
    source.dispose();
  });
}
