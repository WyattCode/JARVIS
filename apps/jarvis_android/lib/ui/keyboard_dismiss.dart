import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

void _dismissKeyboard(PointerDownEvent event) {
  FocusManager.instance.primaryFocus?.unfocus();
}

void _dismissKeyboardUp(PointerUpEvent event) {
  FocusManager.instance.primaryFocus?.unfocus();
}

/// `onTapOutside` for text fields: on iOS a tap anywhere else hides the keyboard. Elsewhere it is null, so Flutter's
/// own default (which Android's mouse/stylus users rely on) is kept untouched.
///
/// It fires on finger DOWN, so it also hides the keyboard under a finger that starts a long-press selection or a scroll;
/// chat text fields use [dismissKeyboardOnTapUpOutside] instead.
TapRegionCallback? get dismissKeyboardOnTapOutside =>
    defaultTargetPlatform == TargetPlatform.iOS ? _dismissKeyboard : null;

/// `onTapUpOutside` for text fields: the keyboard goes when the finger LIFTS outside the field, so a press that turns
/// into a selection or a drag has not moved the page under it yet.
TapRegionUpCallback? get dismissKeyboardOnTapUpOutside =>
    defaultTargetPlatform == TargetPlatform.iOS ? _dismissKeyboardUp : null;
