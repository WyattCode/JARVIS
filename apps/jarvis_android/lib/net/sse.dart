import 'dart:convert';

/// Handles UTF-8 split across TCP chunks, CRLF, comments, multiline SSE data.
Stream<String> sseData(Stream<List<int>> bytes) async* {
  final data = <String>[];
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield data.join('\n');
        data.clear();
      }
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    if (field != 'data') continue;
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    data.add(value);
  }
  // A final record without a blank separator is useful, but callers must still
  // require [DONE] to distinguish a complete generation from a broken stream.
  if (data.isNotEmpty) yield data.join('\n');
}
