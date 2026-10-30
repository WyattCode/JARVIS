import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

/// A window of a straight (bar-type) phone or a foldable, as the chat page sees it.
class Device {
  const Device(
    this.name,
    this.size, {
    this.safe = EdgeInsets.zero,
    this.layout = DuoLayout.none,
  });
  final String name;
  final Size size;
  final EdgeInsets safe;
  final DuoLayout layout;

  @override
  String toString() => name;
}

/// Straight iPhones, portrait and landscape (Dynamic Island on a side in landscape: both sides are treated as 62).
const straightPhones = [
  Device(
    '17 Pro Max portrait',
    Size(440, 956),
    safe: EdgeInsets.only(top: 62, bottom: 34),
  ),
  Device(
    '17 Pro Max landscape',
    Size(956, 440),
    safe: EdgeInsets.only(left: 62, right: 62, bottom: 21),
  ),
  Device(
    '17 Pro portrait',
    Size(402, 874),
    safe: EdgeInsets.only(top: 62, bottom: 34),
  ),
  Device(
    '17 Pro landscape',
    Size(874, 402),
    safe: EdgeInsets.only(left: 62, right: 62, bottom: 21),
  ),
  Device(
    '17 portrait',
    Size(393, 852),
    safe: EdgeInsets.only(top: 59, bottom: 34),
  ),
  Device(
    'Air portrait',
    Size(420, 912),
    safe: EdgeInsets.only(top: 62, bottom: 34),
  ),
  Device('SE portrait', Size(375, 667), safe: EdgeInsets.only(top: 20)),
  Device('SE landscape', Size(667, 375)),
];

/// Pumps the chat page in [device]. [keyboard] is the height of the on-screen keyboard (it takes the home indicator's
/// room with it), [scale] the system text size.
Future<JarvisController> pumpDevice(
  WidgetTester t,
  Device device, {
  double keyboard = 0,
  double scale = 1,
  bool dark = false,
  TargetPlatform platform = TargetPlatform.iOS,
  void Function(JarvisController)? seed,
  ValueNotifier<DuoLayout>? notifier,
  FakeApi? api,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = device.size;
  final safe = device.safe;
  t.view.padding = FakeViewPadding(
    left: safe.left,
    top: safe.top,
    right: safe.right,
    bottom: keyboard > 0 ? 0 : safe.bottom,
  );
  t.view.viewPadding = FakeViewPadding(
    left: safe.left,
    top: safe.top,
    right: safe.right,
    bottom: safe.bottom,
  );
  t.view.viewInsets = FakeViewPadding(bottom: keyboard);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    t.view.resetDevicePixelRatio();
    t.view.resetPhysicalSize();
    t.view.resetPadding();
    t.view.resetViewPadding();
    t.view.resetViewInsets();
    t.platformDispatcher.clearTextScaleFactorTestValue();
  });
  final c = JarvisController(api ?? FakeApi(), MemoryVault());
  await c.initialize();
  addTearDown(c.dispose);
  seed?.call(c);
  await t.pumpWidget(
    DuoLayoutScope(
      layout: notifier ?? ValueNotifier(device.layout),
      child: MaterialApp(
        theme: ThemeData(
          platform: platform,
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
        home: JarvisHome(controller: c),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 400));
  return c;
}

/// A few messages, one of them long enough to wrap many times.
void someMessages(JarvisController c) => c.current.messages
  ..add(ChatMessage('user', '你好，请介绍一下你自己。' * 3))
  ..add(ChatMessage('assistant', '我是 JARVIS，一个可以帮你思考、写作和编程的助手。' * 12));

/// The on-screen rectangles of every widget [finder] matches.
List<Rect> rectsOf(WidgetTester t, Finder finder) => [
  for (final element in finder.evaluate())
    if (element.renderObject case final RenderBox box when box.attached)
      box.localToGlobal(Offset.zero) & box.size,
];
