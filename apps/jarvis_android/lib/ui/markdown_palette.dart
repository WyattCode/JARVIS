import 'package:flutter/material.dart';

/// The iOS app's own palette (Design.swift `Palette`) for the pieces of a chat reply that must match it exactly: the
/// Material colour scheme is close to it, but its light-theme text-variant colour and its cyan are not the same.
class ChatPalette {
  const ChatPalette._(this.dark);

  /// The palette of [brightness] (the theme's, usually).
  factory ChatPalette.of(BuildContext context) =>
      ChatPalette._(Theme.of(context).brightness == Brightness.dark);

  final bool dark;

  /// Text-like uses of the cyan: links, the confirmed state of a button.
  Color get accent => dark ? const Color(0xff8fdceb) : const Color(0xff137589);

  /// The one hairline around cards, tables and rules.
  Color get outlineVariant =>
      dark ? const Color(0xff303036) : const Color(0xffdce3e1);

  /// Secondary text, quiet icons.
  Color get onSurfaceVariant =>
      dark ? const Color(0xffa1a1aa) : const Color(0xff3f484b);

  /// Cards.
  Color get card => dark ? const Color(0xff121214) : const Color(0xffffffff);

  /// Code blocks, tiles, the tinted header of a table.
  Color get containerHigh =>
      dark ? const Color(0xff1c1c20) : const Color(0xffedf0ef);
}
