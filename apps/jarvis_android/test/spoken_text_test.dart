import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/voice/spoken_text.dart';

void main() {
  group('SpokenText', () {
    test('Markdown marks are not shown, bold runs are kept', () {
      final s = SpokenText('# 标题\n这是**重点**和`代码`，[链接](http://x)。\n- 项目');
      expect(s.plain, '标题\n这是重点和代码，链接。\n· 项目');
      // The heading line, and "重点" (five characters into the second line's
      // start at offset 3).
      expect(s.bold, [(0, 2), (5, 7)]);
    });

    test('a ** still waiting for its partner already bolds what follows', () {
      final s = SpokenText('说**正在');
      expect(s.plain, '说正在');
      expect(s.bold, [(1, 3)]);
    });

    test('a star between two spaces is a sign and stays', () {
      expect(SpokenText('2 * 3').plain, '2 * 3');
    });

    test('code fences are shown as written and not weighed as marks', () {
      final s = SpokenText('先\n```\na*b\n```\n后');
      expect(s.plain, '先\na*b\n后');
      expect(s.bold, isEmpty);
    });

    test('the characters cover the text, a picture counts as one', () {
      final s = SpokenText('a👍🏽b');
      expect(s.clusters.first.$1, 0);
      expect(s.clusters.last.$2, s.plain.length);
      for (var i = 1; i < s.clusters.length; i++) {
        expect(s.clusters[i].$1, s.clusters[i - 1].$2);
      }
      expect(s.clusters.length, 3);
    });

    test(
      'position walks the weights: a comma rests, a full stop rests longer',
      () {
        // 你 1, 好 1, ， 1.2, 世 1, 界 1, 。 2.5 -> 7.7 in all
        final s = SpokenText('你好，世界。');
        const pace = .19;
        expect(s.totalWeight, closeTo(7.7, 1e-9));
        expect(s.position(0, pace), 0);
        expect(s.position(.5 * pace, pace), closeTo(.5, 1e-9));
        expect(s.position(1 * pace, pace), closeTo(1, 1e-9));
        expect(s.position(2.6 * pace, pace), closeTo(2.5, 1e-9));
        // The stop's own time is a rest on the stop.
        expect(s.position(5.2 * pace, pace), closeTo(5, 1e-9));
        expect(s.position(6.45 * pace, pace), closeTo(5.5, 1e-9));
        // Past the end: all of them.
        expect(s.position(100, pace), 6);
        expect(s.position(double.nan, pace), isNull);
        expect(SpokenText('').position(1, pace), isNull);
      },
    );

    test('a run of stops is one pause, not one for every mark', () {
      expect(SpokenText('好……').totalWeight, closeTo(1 + 2.5, 1e-9));
      expect(SpokenText('好?!').totalWeight, closeTo(1 + 2.5, 1e-9));
    });

    test(
      'the pace that fills the sound, believed only in a voice\'s range',
      () {
        final s = SpokenText('你好，世界。');
        expect(s.paceForTotal(1.54), closeTo(.2, 1e-9));
        expect(s.paceForTotal(100), SpokenText.paceMax);
        expect(s.paceForTotal(.01), SpokenText.paceMin);
        expect(s.paceForTotal(0), SpokenText.defaultPace);
        expect(SpokenText.paceBelieved(.19), isTrue);
        expect(SpokenText.paceBelieved(.9), isFalse);
      },
    );
  });

  group('SpeechProgress', () {
    final text = SpokenText('你好，世界。');
    test('is followed only while live or cut', () {
      const done = SpeechProgress(
        played: 1,
        total: 1.5,
        pace: .19,
        live: false,
        cut: false,
      );
      expect(done.position(text), isNull);
      const live = SpeechProgress(
        played: 0,
        total: null,
        pace: .19,
        live: true,
        cut: false,
      );
      // The edge is placed a little ahead of the sound.
      expect(
        live.position(text),
        closeTo(text.position(SpeechProgress.lead, .19)!, 1e-9),
      );
    });

    test('a known total sets the pace', () {
      const known = SpeechProgress(
        played: 0,
        total: 1.54,
        pace: .19,
        live: true,
        cut: false,
      );
      expect(
        known.position(text),
        closeTo(
          text.position(SpeechProgress.lead, text.paceForTotal(1.54))!,
          1e-9,
        ),
      );
    });
  });

  group('ReadingEdge', () {
    test('moves on at most as fast as a quick speaker and never goes back', () {
      final edge = ReadingEdge();
      expect(edge.advance(10, 0), 10);
      // An estimate that jumped 50 characters ahead is not followed at once.
      expect(
        edge.advance(60, .1),
        closeTo(10 + ReadingEdge.maxSpeed * .1, 1e-9),
      );
      final at = edge.value!;
      // An estimate behind the edge leaves it where it is.
      expect(edge.advance(5, .2), at);
    });

    test('a look after a long gap sets the edge at once', () {
      final edge = ReadingEdge();
      edge.advance(10, 0);
      expect(edge.advance(80, 5), 80);
    });

    test('a cut reply keeps the edge where it was drawn', () {
      final edge = ReadingEdge();
      expect(edge.freeze(7), 7);
      edge.advance(9, 10);
      expect(edge.freeze(30), 9);
      edge.reset();
      expect(edge.value, isNull);
    });
  });
}
