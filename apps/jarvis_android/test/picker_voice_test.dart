import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/voice_picker.dart';

import 'support.dart';
import 'voice_support.dart';

class TwoEngineApi extends VoiceApi {
  TwoEngineApi({this.engines = 2});
  final int engines;
  @override
  Future<List<ModelInfo>> models() async => [
    ModelInfo('chat', 'Chat'),
    ModelInfo(
      'speech-a',
      'drama-3',
      kind: 'speech',
      defaultVoice: 'Atlas',
      voices: const [
        VoiceInfo('Atlas', 'Atlas', 'A clear, steady voice'),
        VoiceInfo('Mae', 'Mae', ''),
      ],
    ),
    if (engines > 1)
      ModelInfo(
        'speech-b',
        'fish-2',
        kind: 'speech',
        defaultVoice: 'Zed',
        voices: const [VoiceInfo('Zed', 'Zed', 'Other')],
      ),
  ];
}

void main() {
  late JarvisController c;

  Future<void> open(WidgetTester t, {int engines = 2, Size? size}) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size ?? const Size(400, 800);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    c = JarvisController(
      TwoEngineApi(engines: engines),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await c.initialize();
    await c.login('Wyatt', 'test');
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showVoicePicker(context, c),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('Card design: title, one card of voices, check gutter, 44pt '
      'preview', (t) async {
    await open(t, engines: 1);
    expect(find.text('选择音色'), findsOneWidget);
    final title = t.widget<Text>(find.text('选择音色'));
    expect(title.style?.fontSize, 20);
    expect(title.style?.fontWeight, FontWeight.w600);
    expect(find.byKey(const Key('sheet-grabber')), findsOneWidget);
    // One engine: no engine row.
    expect(find.byKey(const Key('voice-engine-row')), findsNothing);
    expect(find.byKey(const Key('voice-list')), findsOneWidget);
    expect(t.widget<Text>(find.text('Atlas')).style?.fontSize, 16);
    expect(
      t.widget<Text>(find.text('A clear, steady voice')).style?.fontSize,
      13,
    );
    expect(
      t.getSize(find.byKey(const ValueKey('voice-preview-Atlas'))),
      const Size(44, 44),
    );
    // The default voice is checked, the other is not.
    double opacity(String id) => t
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byKey(ValueKey('voice-check-$id')),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(opacity('Atlas'), 1);
    expect(opacity('Mae'), 0);
    await t.tap(find.text('Mae'));
    await t.pumpAndSettle();
    expect(c.settings.voices['speech-a'], 'Mae');
    expect(opacity('Mae'), 1);
    expect(opacity('Atlas'), 0);
  });

  testWidgets('Opens at half the window, can be drawn up, and closes from '
      'the lower height', (t) async {
    await open(t, engines: 1, size: const Size(400, 800));
    final body = find.byKey(const Key('voice-picker'));
    expect(t.getRect(find.byType(DraggableScrollableSheet)).height, 400);
    await t.drag(body, const Offset(0, -400));
    await t.pumpAndSettle();
    expect(
      t.getRect(find.byType(DraggableScrollableSheet)).height,
      closeTo(800 - 24, 30),
    );
    await t.drag(body, const Offset(0, 900));
    await t.pumpAndSettle();
    expect(find.text('选择音色'), findsNothing);
  });

  testWidgets('Dragging the medium sheet down closes it', (t) async {
    await open(t, engines: 1);
    await t.drag(find.byKey(const Key('voice-picker')), const Offset(0, 300));
    await t.pumpAndSettle();
    expect(find.text('选择音色'), findsNothing);
  });

  testWidgets('Several engines show one engine row that switches the voices', (
    t,
  ) async {
    await open(t);
    expect(find.byKey(const Key('voice-engine-row')), findsOneWidget);
    expect(find.text('语音引擎'), findsOneWidget);
    expect(find.text('Drama-3'), findsOneWidget);
    await t.tap(find.text('语音引擎'));
    await t.pumpAndSettle();
    await t.tap(find.text('Fish-2'));
    await t.pumpAndSettle();
    expect(c.settings.speechModel, 'speech-b');
    expect(find.text('Zed'), findsOneWidget);
    expect(find.text('Mae'), findsNothing);
  });

  testWidgets('Preview shows a spinner while loading, stop while playing, and '
      'the error in the error colour', (t) async {
    await open(t, engines: 1);
    final api = c.api as TwoEngineApi;
    final button = find.byKey(const ValueKey('voice-preview-Atlas'));
    expect(find.byIcon(Icons.play_arrow_rounded), findsNWidgets(2));
    await t.tap(button);
    await t.pump();
    await t.pump();
    expect(c.voice.previewing, true);
    expect(
      find.descendant(
        of: button,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('停止试听 Atlas'), findsOneWidget);
    // Fail the preview: the error shows as 13pt text in the error colour.
    api.previews['Atlas']!.completeError(StateError('x'));
    await t.pump();
    await t.pump();
    await t.pump();
    final error = find.byKey(const Key('voice-picker-error'));
    expect(error, findsOneWidget);
    final style = t.widget<Text>(error).style!;
    expect(style.fontSize, 13);
    expect(style.color, Theme.of(t.element(error)).colorScheme.error);
    expect(find.byTooltip('试听 Atlas'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
  });
}
