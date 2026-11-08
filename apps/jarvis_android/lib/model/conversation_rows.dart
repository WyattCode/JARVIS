import 'conversation.dart';

/// One row of the conversation list: a heading (今天 / 昨天 / 更早) or a
/// conversation. (A port of the iOS app's `ConversationRows`.)
class SidebarRow {
  const SidebarRow({
    required this.isHeader,
    required this.id,
    required this.title,
    this.selected = false,
    this.generating = false,
  });
  final bool isHeader;
  final String id, title;
  final bool selected, generating;
}

class ConversationRows {
  /// The conversation list shows a search field from this many conversations on.
  static const searchFrom = 6;

  /// When [c] was last active, read from the timestamp in the id of its latest
  /// message (ids are made from the clock); null for ids that are not.
  static DateTime? lastActive(Conversation c) {
    final id = c.messages.isEmpty ? c.id : c.messages.last.id;
    final micros = int.tryParse(id.split('-').first);
    if (micros == null ||
        micros < 946684800000000 ||
        micros > 4102444800000000) {
      return null;
    }
    return DateTime.fromMicrosecondsSinceEpoch(micros);
  }

  /// The conversations that match [query] (title, or any message), in the
  /// order given, with the headings between them whenever more than one of the
  /// groups is present.
  static ({List<SidebarRow> rows, int found}) rows(
    List<Conversation> all, {
    String query = '',
    String? selected,
    bool Function(String id)? generating,
    DateTime? now,
    bool grouped = true,
  }) {
    final needle = query.trim().toLowerCase();
    final shown = needle.isEmpty
        ? all
        : all
              .where(
                (c) =>
                    c.title.toLowerCase().contains(needle) ||
                    c.messages.any(
                      (m) => !m.hidden && m.text.toLowerCase().contains(needle),
                    ),
              )
              .toList();
    final at = now ?? DateTime.now();
    final today = DateTime(at.year, at.month, at.day);
    final yesterday = DateTime(at.year, at.month, at.day - 1);
    String group(Conversation c) {
      final last = lastActive(c);
      if (last == null) return '更早';
      final day = DateTime(last.year, last.month, last.day);
      if (!day.isBefore(today)) return '今天';
      return !day.isBefore(yesterday) ? '昨天' : '更早';
    }

    final groups = shown.map(group).toList();
    final headed = grouped && groups.toSet().length >= 2;
    final rows = <SidebarRow>[];
    String? previous;
    for (var i = 0; i < shown.length; i++) {
      final c = shown[i];
      if (headed && groups[i] != previous) {
        previous = groups[i];
        rows.add(
          SidebarRow(
            isHeader: true,
            id: 'header-${groups[i]}',
            title: groups[i],
          ),
        );
      }
      rows.add(
        SidebarRow(
          isHeader: false,
          id: c.id,
          title: c.title,
          selected: c.id == selected,
          generating: generating?.call(c.id) ?? false,
        ),
      );
    }
    return (rows: rows, found: shown.length);
  }
}
