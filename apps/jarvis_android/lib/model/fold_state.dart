import 'dart:ui'
    show DisplayFeature, DisplayFeatureState, DisplayFeatureType, Rect, Size;

/// How the hinge stands, as the system reports it through the window's display
/// features. Nothing here is a device constant: the crease is whatever the
/// system names, in the window's own coordinates.
enum FoldPosture {
  /// The system names no fold (a straight phone, or a display without one).
  none,

  /// A fold exists and the hinge is open flat (or its angle is not reported).
  flat,

  /// The hinge is partly open: the inner display stands as two screens, one on
  /// each side of the crease.
  halfOpened,
}

/// The fold of the window, if the system names one.
class FoldState {
  const FoldState({this.posture = FoldPosture.none, this.bounds = Rect.zero});

  /// No fold: the layout behaves exactly as it does without this class.
  static const none = FoldState();

  final FoldPosture posture;

  /// The crease, in the window's coordinates.
  final Rect bounds;

  bool get present => posture != FoldPosture.none;
  bool get halfOpened => posture == FoldPosture.halfOpened;

  /// The crease runs from the top of the window to its bottom, so the two
  /// screens stand side by side (a hinge across the short side of the device,
  /// with the device held sideways). A crease across the window (screens one
  /// above the other) is not a side-by-side arrangement.
  ///
  /// A fold that takes no room (zero width) still splits: the system names the
  /// line where the screens meet.
  bool isVertical(Size window) =>
      present &&
      bounds.height > 0 &&
      bounds.height >= window.height - 1 &&
      bounds.width < window.width;

  /// Half-folded with the screens side by side.
  bool splitsSideBySide(Size window) => halfOpened && isVertical(window);

  /// The first fold or hinge among the display features (cutouts are not
  /// folds). With none, [FoldState.none].
  factory FoldState.fromFeatures(Iterable<DisplayFeature> features) {
    for (final f in features) {
      if (f.type != DisplayFeatureType.fold &&
          f.type != DisplayFeatureType.hinge) {
        continue;
      }
      return FoldState(
        posture: f.state == DisplayFeatureState.postureHalfOpened
            ? FoldPosture.halfOpened
            : FoldPosture.flat,
        bounds: f.bounds,
      );
    }
    return FoldState.none;
  }

  @override
  bool operator ==(Object other) =>
      other is FoldState && other.posture == posture && other.bounds == bounds;

  @override
  int get hashCode => Object.hash(posture, bounds);

  @override
  String toString() => 'FoldState($posture, $bounds)';
}
