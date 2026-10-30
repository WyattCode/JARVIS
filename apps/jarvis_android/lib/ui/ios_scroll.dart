import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// iOS pages always respond to a drag (with the platform's rubber band) even when their content fits the screen,
/// and dragging also hides the keyboard. Other platforms keep Flutter's defaults (null / manual).
ScrollPhysics? get iosScrollPhysics =>
    defaultTargetPlatform == TargetPlatform.iOS
    ? const AlwaysScrollableScrollPhysics()
    : null;

ScrollViewKeyboardDismissBehavior get iosKeyboardDismiss =>
    defaultTargetPlatform == TargetPlatform.iOS
    ? ScrollViewKeyboardDismissBehavior.onDrag
    : ScrollViewKeyboardDismissBehavior.manual;
