import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/login_art.dart';

void main() {
  testWidgets(
    'Compact phone and fold identity aligns status and explanation on one text baseline without overlap',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      for (final size in [
        const Size(400, 869),
        const Size(425, 623),
        const Size(860, 608),
      ]) {
        t.view.physicalSize = size;
        await t.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: size, disableAnimations: true),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: VoiceIdentityStage(
                  compact: true,
                  windowHeight: size.height,
                  identity: 'inline',
                  status: '已就绪',
                  hint: '按住按钮开始说话',
                  mode: ReactorMode.idle,
                  onTap: () {},
                  transcript: const SizedBox(key: Key('transcript')),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        final status = find.text('已就绪'), hint = find.text('按住按钮开始说话');
        final sr = t.renderObject<RenderParagraph>(status),
            hr = t.renderObject<RenderParagraph>(hint);
        final sb =
            t.getTopLeft(status).dy +
            sr.getDryBaseline(sr.constraints, TextBaseline.alphabetic)!;
        final hb =
            t.getTopLeft(hint).dy +
            hr.getDryBaseline(hr.constraints, TextBaseline.alphabetic)!;
        expect(sb, closeTo(hb, .1), reason: '$size shared baseline');
        expect(t.getRect(hint).left, greaterThan(t.getRect(status).right));
        expect(t.getRect(hint).right, lessThanOrEqualTo(size.width - 20));
        expect(
          t.getSize(find.byKey(const Key('transcript'))).height,
          greaterThan(60),
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      }
    },
  );
}
