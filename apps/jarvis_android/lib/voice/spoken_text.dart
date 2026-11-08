// ignore: depend_on_referenced_packages
import 'package:characters/characters.dart';

/// A reply's words laid against its sound, so the call page can show where the
/// voice is.
///
/// The server gives no times for the words, only the text and the audio. What
/// is known exactly is how much of the audio has been played; every character
/// is given the time it is likely to take to say (its weight), and the played
/// time is looked up in that. The place found is an estimate: it can run ahead
/// of or behind the voice, by a few words, sometimes more. It never jumps, so
/// the page draws it as a soft edge moving on, not as a mark on a word.
///
/// (A port of the iOS app's `SpokenText`, so both apps light the words alike.)
class SpokenText {
  SpokenText._(this.plain, this.bold, this.clusters, this._cumulative);

  /// What the page shows: the reply without its Markdown marks (a `**` is not
  /// said, and not worth showing either).
  final String plain;

  /// Runs to set heavier (UTF-16 offsets into [plain]).
  final List<(int, int)> bold;

  /// The characters of [plain] as the reader sees them (UTF-16 offsets);
  /// together they cover all of it.
  final List<(int, int)> clusters;

  /// Time before each character and in all, in units of one spoken Chinese
  /// character (`cumulative.length == clusters.length + 1`).
  final List<double> _cumulative;

  /// Seconds one unit takes when nothing better is known (measured on the
  /// service's voice: 0.186 to 0.192).
  static const defaultPace = 0.19;

  /// Paces outside this are not a voice (a reply whose words and sound do not
  /// belong together): they are not believed.
  static const paceMin = 0.08, paceMax = 0.5;
  static bool paceBelieved(double pace) => pace >= paceMin && pace <= paceMax;

  factory SpokenText(String raw) {
    final plain = StringBuffer();
    final bold = <(int, int)>[];
    var offset = 0;
    var inFence = false;
    final lines = raw.split('\n');
    for (var n = 0; n < lines.length; n++) {
      var line = lines[n];
      if (line.trim().startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      var headed = false;
      if (!inFence) {
        final heading = RegExp(r'^\s{0,3}#{1,6}\s+').firstMatch(line);
        final quote = RegExp(r'^\s{0,3}>\s?').firstMatch(line);
        final bullet = RegExp(r'^\s*[-*+]\s+').firstMatch(line);
        if (heading != null) {
          line = line.substring(heading.end);
          headed = true;
        } else if (quote != null) {
          line = line.substring(quote.end);
        } else if (bullet != null) {
          line = '· ${line.substring(bullet.end)}';
        }
      }
      final (text, runs) = inFence ? (line, <(int, int)>[]) : _inline(line);
      final base = offset;
      plain.write(text);
      final length = text.length;
      for (final run in runs) {
        bold.add((base + run.$1, base + run.$2));
      }
      if (headed && length > 0) bold.add((base, base + length));
      offset += length;
      if (n < lines.length - 1) {
        plain.write('\n');
        offset += 1;
      }
    }
    final text = plain.toString();
    final units = text.codeUnits;
    final each = _weights(units);
    final clusters = <(int, int)>[];
    final cumulative = <double>[0];
    var at = 0;
    for (final character in text.characters) {
      final end = at + character.length;
      clusters.add((at, end));
      var sum = 0.0;
      for (var i = at; i < end; i++) {
        sum += each[i];
      }
      cumulative.add(cumulative.last + sum);
      at = end;
    }
    return SpokenText._(text, _merged(bold), clusters, cumulative);
  }

  bool get isEmpty => clusters.isEmpty;
  double get totalWeight => _cumulative.last;

  /// How far the voice is [seconds] into the reply when one unit takes [pace]
  /// seconds: the number of characters it has said, with the part of the one
  /// it is on (so 3.5 is half way through the fourth). All of them when it is
  /// past the end.
  double? position(double seconds, double pace) {
    if (clusters.isEmpty || pace <= 0 || !seconds.isFinite) return null;
    final units = (seconds < 0 ? 0 : seconds) / pace;
    if (units >= totalWeight) return clusters.length.toDouble();
    // The first character that ends after this time (characters that take no
    // time are passed over).
    var low = 0, high = clusters.length - 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_cumulative[mid + 1] > units) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    final width = _cumulative[low + 1] - _cumulative[low];
    return low + (width > 0 ? (units - _cumulative[low]) / width : 0);
  }

  /// The pace that makes these words fill [seconds] of sound, once all of the
  /// sound is known.
  double paceForTotal(double seconds) {
    final w = totalWeight;
    if (w <= 0 || seconds <= 0 || !seconds.isFinite) return defaultPace;
    return (seconds / w).clamp(paceMin, paceMax).toDouble();
  }

  /// Inline marks of one line: `**bold**` is kept as a run, `code`,
  /// `*emphasis*` and `[text](link)` lose their marks. A `**` still waiting
  /// for its partner (the reply is being written) already bolds what follows.
  static (String, List<(int, int)>) _inline(String line) {
    final chars = line.characters.toList();
    final out = StringBuffer();
    final runs = <(int, int)>[];
    var length = 0;
    int? boldFrom;
    var i = 0;
    void emit(String s) {
      out.write(s);
      length += s.length;
    }

    while (i < chars.length) {
      final c = chars[i];
      if (c == '*' && i + 1 < chars.length && chars[i + 1] == '*') {
        if (boldFrom != null) {
          if (length > boldFrom) runs.add((boldFrom, length));
          boldFrom = null;
        } else {
          boldFrom = length;
        }
        i += 2;
        while (i < chars.length && chars[i] == '*') {
          i++;
        }
        continue;
      }
      if (c == '*' || c == '`') {
        // A lone star or a backtick is a mark; a star between two spaces
        // ("2 * 3") is a sign, and stays.
        final spaced =
            c == '*' &&
            i > 0 &&
            chars[i - 1] == ' ' &&
            i + 1 < chars.length &&
            chars[i + 1] == ' ';
        if (spaced) emit('*');
        i++;
        continue;
      }
      if (c == '[') {
        final close = chars.indexOf(']', i);
        if (close != -1 &&
            close + 1 < chars.length &&
            chars[close + 1] == '(') {
          final end = chars.indexOf(')', close + 1);
          if (end != -1) {
            emit(chars.sublist(i + 1, close).join());
            i = end + 1;
            continue;
          }
        }
      }
      emit(c);
      i++;
    }
    if (boldFrom != null && length > boldFrom) runs.add((boldFrom, length));
    return (out.toString(), runs);
  }

  static List<(int, int)> _merged(List<(int, int)> runs) {
    final sorted = [...runs.where((r) => r.$2 > r.$1)]
      ..sort((a, b) => a.$1.compareTo(b.$1));
    final result = <(int, int)>[];
    for (final run in sorted) {
      if (result.isNotEmpty && run.$1 <= result.last.$2) {
        final last = result.removeLast();
        result.add((last.$1, last.$2 > run.$2 ? last.$2 : run.$2));
      } else {
        result.add(run);
      }
    }
    return result;
  }

  static final _enders = '。！？!?；;…'.codeUnits.toSet();

  /// The time of every UTF-16 unit, in units of one spoken Chinese character:
  /// a character 1, a digit about 1.3 (a number is said as its words), a Latin
  /// letter a third, a comma a short pause and a full stop a long one (the
  /// pause is the stop's own time, so the voice rests on it). A run like "?!"
  /// or "……" is one pause, not one for every mark.
  static List<double> _weights(List<int> units) {
    final result = List<double>.filled(units.length, 0);
    var afterEnd = false;
    for (var i = 0; i < units.length; i++) {
      final c = units[i];
      final dot =
          c == 0x2E &&
          (i + 1 >= units.length ||
              units[i + 1] == 0x20 ||
              units[i + 1] == 0x0A);
      if (_enders.contains(c) || dot) {
        if (!afterEnd) result[i] = 2.5;
        afterEnd = true;
        continue;
      }
      afterEnd = false;
      if (c >= 0x30 && c <= 0x39) {
        result[i] = 1.3;
      } else if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) {
        result[i] = 0.35;
      } else if (c == 0x20 || c == 0x09 || c == 0x3000) {
        result[i] = 0;
      } else if (c == 0x0A) {
        result[i] = 2;
      } else if (c == 0x2C ||
          c == 0xFF0C ||
          c == 0x3001 ||
          c == 0x3A ||
          c == 0xFF1A) {
        result[i] = 1.2;
      } else if (c == 0x2E) {
        result[i] = 0.5;
      } else if ((c >= 0x4E00 && c <= 0x9FFF) ||
          (c >= 0x3400 && c <= 0x4DBF) ||
          (c >= 0x3040 && c <= 0x30FF) ||
          (c >= 0xAC00 && c <= 0xD7AF)) {
        result[i] = 1;
      } else {
        result[i] = 0.3;
      }
    }
    return result;
  }
}

/// How far the voice has got in the reply on screen
/// (`VoiceSession.speechProgress`).
class SpeechProgress {
  const SpeechProgress({
    required this.played,
    required this.total,
    required this.pace,
    required this.live,
    required this.cut,
  });

  /// Seconds of this reply's sound already played.
  final double played;

  /// Seconds of sound in all, once all of it has arrived.
  final double? total;

  /// Seconds one spoken character takes, for as long as [total] is not known.
  final double pace;

  /// The reply is being said now.
  final bool live;

  /// The reply was cut off, and [played] is where.
  final bool cut;

  /// The eye is on a word a moment before it is said, and the lit edge is drawn
  /// a few characters behind its front: so the edge is placed as far ahead of
  /// the sound as that, which is what makes it look level with the voice.
  static const lead = 0.5;

  /// How many characters of [text] the voice has said, null when the reply is
  /// not being followed any more (it was said to the end).
  double? position(SpokenText text) {
    if (!live && !cut) return null;
    return text.position(
      played + lead,
      total == null ? pace : text.paceForTotal(total!),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SpeechProgress &&
      other.played == played &&
      other.total == total &&
      other.pace == pace &&
      other.live == live &&
      other.cut == cut;

  @override
  int get hashCode => Object.hash(played, total, pace, live, cut);
}

/// The edge the page draws, which follows the estimated place of the voice but
/// never jumps to it: it moves on at most as fast as a quick speaker (a few
/// times the speed of speech) and never goes back. An estimate that is wrong
/// therefore shows as the edge being a little early or late, not as the lit
/// part leaping across the text.
class ReadingEdge {
  /// Where the edge is drawn now (characters said), null before the first
  /// estimate of a reply.
  double? value;
  double? _at;

  /// The fastest the edge moves, in characters a second (speech is about five).
  static const maxSpeed = 14.0;

  /// Longer than this between two looks (the page was away) and the edge is set
  /// to the estimate at once.
  static const longestGap = 1.0;

  void reset() {
    value = null;
    _at = null;
  }

  /// The edge at [now] (seconds, any clock) given the estimate [raw].
  double advance(double raw, double now) {
    final current = value, last = _at;
    if (current == null ||
        last == null ||
        now < last ||
        now - last > longestGap) {
      value = raw;
      _at = now;
      return raw;
    }
    final next = raw > current
        ? (raw < current + maxSpeed * (now - last)
              ? raw
              : current + maxSpeed * (now - last))
        : current;
    value = next;
    _at = now;
    return next;
  }

  /// A reply that was cut off keeps the edge where it was drawn (or at the
  /// estimate, if nothing was drawn yet).
  double freeze(double raw) {
    final current = value;
    if (current != null) return current;
    value = raw;
    return raw;
  }
}
