import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/voice/audio_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cc.odn.jarvis/audio');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'A failed native feed is reported but does not poison all later audio',
    () async {
      final audio = NativeAudioDevice();
      var attempts = 0;
      final accepted = <Uint8List>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'feed') {
          attempts++;
          if (attempts == 1) throw PlatformException(code: 'audio_failed');
          accepted.add((call.arguments as Map)['bytes'] as Uint8List);
        }
        return null;
      });
      await expectLater(
        audio.feed(Uint8List(9600)),
        throwsA(isA<PlatformException>()),
      );
      final following = Uint8List.fromList(List.filled(4800, 12));
      await audio.feed(following);
      await audio.finish();
      expect(attempts, 2);
      expect(accepted.single, following);
      await audio.stop();
    },
  );

  test('Stopping after a failed feed permits a fresh output session', () async {
    final audio = NativeAudioDevice();
    var fail = true;
    final sizes = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'feed') {
        if (fail) throw PlatformException(code: 'audio_failed');
        sizes.add(((call.arguments as Map)['bytes'] as Uint8List).length);
      }
      return null;
    });
    await expectLater(
      audio.feed(Uint8List(9600)),
      throwsA(isA<PlatformException>()),
    );
    await audio.stop();
    fail = false;
    await audio.feed(Uint8List(4800));
    expect(
      sizes,
      isEmpty,
      reason: 'A new session restores the initial jitter buffer',
    );
    await audio.feed(Uint8List(4800));
    await audio.finish();
    expect(sizes, [9600]);
    await audio.stop();
  });
}
