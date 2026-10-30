import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/ui/duo_layout.dart';

import 'support.dart';

/// One device pose of the compatibility matrix: logical size and the safe-area insets iOS reports for it.
class Pose {
  const Pose(this.name, this.size, this.insets);
  final String name;
  final Size size;
  final EdgeInsets insets;
  bool get portrait => size.height > size.width;
  Rect get safe => Rect.fromLTRB(
    insets.left,
    insets.top,
    size.width - insets.right,
    size.height - insets.bottom,
  );
}

const straightPoses = [
  Pose(
    'Pro Max portrait',
    Size(440, 956),
    EdgeInsets.only(top: 62, bottom: 34),
  ),
  Pose(
    'Pro Max landscape',
    Size(956, 440),
    EdgeInsets.only(left: 62, right: 62, bottom: 21),
  ),
  Pose('Pro portrait', Size(402, 874), EdgeInsets.only(top: 62, bottom: 34)),
  Pose(
    'Pro landscape',
    Size(874, 402),
    EdgeInsets.only(left: 62, right: 62, bottom: 21),
  ),
  Pose('17 portrait', Size(393, 852), EdgeInsets.only(top: 59, bottom: 34)),
  Pose(
    '17 landscape',
    Size(852, 393),
    EdgeInsets.only(left: 59, right: 59, bottom: 21),
  ),
  Pose('Air portrait', Size(420, 912), EdgeInsets.only(top: 62, bottom: 34)),
  Pose('SE portrait', Size(375, 667), EdgeInsets.only(top: 20)),
  Pose('SE landscape', Size(667, 375), EdgeInsets.zero),
];

/// The foldable's poses (a bar strip of 84 pt on the right where there is one).
final foldPoses = [
  Pose(
    'outer',
    const Size(466, 678),
    const EdgeInsets.only(right: 84, bottom: 34),
  ),
  Pose(
    'inner landscape',
    const Size(951, 669),
    const EdgeInsets.only(right: 84, bottom: 34),
  ),
  Pose(
    'inner portrait',
    const Size(669, 951),
    const EdgeInsets.only(top: 54, bottom: 34),
  ),
];

const textScales = [1.0, 1.5, 2.4];

final halfFolded = DuoLayout.fromMap({
  'edge': 'right',
  'width': 951.0,
  'height': 669.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
  'regions': [
    {
      'kind': 'division',
      'active': true,
      'x': 455.5,
      'y': 0.0,
      'w': 40.0,
      'h': 669.0,
    },
    {
      'kind': 'occlusion',
      'active': true,
      'x': 867.0,
      'y': 0.0,
      'w': 84.0,
      'h': 124.0,
    },
  ],
});
final flatLandscape = DuoLayout.fromMap({
  'edge': 'right',
  'width': 951.0,
  'height': 669.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
  'regions': [
    {
      'kind': 'division',
      'active': false,
      'x': 455.5,
      'y': 0.0,
      'w': 40.0,
      'h': 669.0,
    },
    {
      'kind': 'occlusion',
      'active': true,
      'x': 867.0,
      'y': 0.0,
      'w': 84.0,
      'h': 124.0,
    },
  ],
});
final outerDisplay = DuoLayout.fromMap({
  'edge': 'right',
  'width': 466.0,
  'height': 678.0,
  'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
  'regions': [
    {
      'kind': 'occlusion',
      'active': true,
      'x': 382.0,
      'y': 0.0,
      'w': 84.0,
      'h': 174.0,
    },
  ],
});

/// The app's light and dark colour schemes closely enough for contrast and overflow checks.
ThemeData themeFor(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff3e899b),
        brightness: brightness,
      ).copyWith(
        surface: dark ? const Color(0xff09090b) : const Color(0xfff9faf9),
        primary: dark ? const Color(0xffd5d5df) : const Color(0xff28596a),
        surfaceContainerLowest: dark
            ? const Color(0xff09090b)
            : const Color(0xffffffff),
        surfaceContainerLow: dark
            ? const Color(0xff121214)
            : const Color(0xffffffff),
        surfaceContainer: dark
            ? const Color(0xff18181b)
            : const Color(0xfff1f3f2),
        onSurface: dark ? const Color(0xffededf1) : null,
        onSurfaceVariant: dark ? const Color(0xffa1a1aa) : null,
        error: dark ? const Color(0xffff9b8c) : null,
        outline: dark ? const Color(0xff36363d) : null,
        outlineVariant: dark
            ? const Color(0xff303036)
            : const Color(0xffdce3e1),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    // The app theme's 48 pt minimum for icon buttons.
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(
        iconSize: WidgetStatePropertyAll(20),
        minimumSize: WidgetStatePropertyAll(Size(48, 48)),
      ),
    ),
  );
}

/// Sizes the test window and its insets (the Dynamic Island / home indicator / strip).
void sizeWindow(WidgetTester t, Size size, EdgeInsets insets) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  t.view.padding = FakeViewPadding(
    left: insets.left,
    top: insets.top,
    right: insets.right,
    bottom: insets.bottom,
  );
  t.view.viewPadding = t.view.padding;
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetPadding);
  addTearDown(t.view.resetViewPadding);
}

/// A MaterialApp with the test text scale, theme and Increase Contrast switch.
Widget appHost(
  Widget home, {
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool highContrast = false,
}) => MaterialApp(
  theme: themeFor(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      highContrast: highContrast,
      disableAnimations: true,
    ),
    child: child!,
  ),
  home: home,
);

Widget withLayout(DuoLayout layout, Widget child) =>
    DuoLayoutScope(layout: ValueNotifier(layout), child: child);

/// A speech engine with two voices, for the pickers.
class SpeechApi extends FakeApi {
  @override
  Future<List<ModelInfo>> models() async => [
    ModelInfo('test-model', 'Test'),
    ModelInfo(
      's1',
      'engine-one',
      kind: 'speech',
      defaultVoice: 'a',
      voices: const [VoiceInfo('a', '星衡', '沉稳'), VoiceInfo('b', '晨曦', '明亮')],
    ),
    ModelInfo('s2', 'engine-two', kind: 'speech', defaultVoice: 'a'),
  ];
}
