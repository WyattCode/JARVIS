import 'package:flutter/widgets.dart' show StringCharacters;

/// Replaces every unpaired surrogate with U+FFFD: `Text` throws on such a string, and a saved one would throw on every launch.
String wellFormed(String text) {
  final units = text.codeUnits;
  List<int>? fixed;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    final high = u >= 0xD800 && u <= 0xDBFF, low = u >= 0xDC00 && u <= 0xDFFF;
    final paired =
        high &&
        i + 1 < units.length &&
        units[i + 1] >= 0xDC00 &&
        units[i + 1] <= 0xDFFF;
    if (paired) {
      fixed?.addAll([u, units[i + 1]]);
      i++;
    } else if (high || low) {
      fixed ??= units.sublist(0, i).toList();
      fixed.add(0xFFFD);
    } else {
      fixed?.add(u);
    }
  }
  return fixed == null ? text : String.fromCharCodes(fixed);
}

/// At most [max] user-perceived characters; an emoji or a flag is never cut in half.
String clipCharacters(String text, int max, {String ellipsis = ''}) {
  final chars = wellFormed(text).characters;
  if (chars.length <= max) return chars.string;
  return '${chars.take(max)}$ellipsis';
}

/// A one-line title: whitespace and line breaks collapse to single spaces, then it is clipped.
String tidyTitle(String text, {int max = 24}) => clipCharacters(
  text.replaceAll(RegExp(r'\s+'), ' ').trim(),
  max,
  ellipsis: '…',
);
