import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Which side of the screen the system keeps its vertical bar strip on (iPhone Duo, iOS 27.1+).
enum DuoBarEdge { none, left, right }

enum DuoRegionKind { division, occlusion }

/// A region the system reserves inside the app view: the fold (division) or the status/camera area (occlusion).
@immutable
class DuoRegion {
  const DuoRegion({
    required this.kind,
    required this.active,
    required this.rect,
    this.margins = EdgeInsets.zero,
  });
  final DuoRegionKind kind;
  final bool active;
  final Rect rect;
  final EdgeInsets margins;

  @override
  bool operator ==(Object other) =>
      other is DuoRegion &&
      other.kind == kind &&
      other.active == active &&
      other.rect == rect &&
      other.margins == margins;
  @override
  int get hashCode => Object.hash(kind, active, rect, margins);
}

@immutable
class DuoSystemBar {
  const DuoSystemBar({
    required this.centerX,
    required this.topCenterY,
    required this.bottomCenterY,
    this.titleCenterY,
  });
  final double centerX, topCenterY, bottomCenterY;

  /// The vertical centre of a standard navigation title on this display (null when the platform did not report it).
  final double? titleCenterY;
  @override
  bool operator ==(Object other) =>
      other is DuoSystemBar &&
      other.centerX == centerX &&
      other.topCenterY == topCenterY &&
      other.bottomCenterY == bottomCenterY &&
      other.titleCenterY == titleCenterY;
  @override
  int get hashCode =>
      Object.hash(centerX, topCenterY, bottomCenterY, titleCenterY);
}

/// iPhone Duo layout facts reported by the native `ai.jarvis.app/duo` channel. Flutter draws its own bars, so
/// the system does not move them into the vertical strip; this tells the UI where that strip is.
@immutable
class DuoLayout {
  const DuoLayout({
    this.edge = DuoBarEdge.none,
    this.size = Size.zero,
    this.safe = EdgeInsets.zero,
    this.regions = const [],
    this.systemBar,
    this.reduceTransparency = false,
  });
  static const none = DuoLayout();

  /// Left, right and bottom spacing of the composer on a foldable iPhone. The home indicator sits ~13pt above the
  /// bottom edge, so 22 leaves ~9pt between it and the composer.
  static const edgeGap = 22.0;

  /// Composer width on the unfolded (regular width) screen, as a fraction of the content pane.
  static const unfoldedContentFactor = .85;

  /// Foldable: width of the message column (your messages and the model's replies) relative to the composer frame.
  static const replyWidthFactor = .95 * .95 * 1.05;

  /// Foldable: the sidebar brand row and the chat header title share one horizontal axis, this far below the top
  /// of the safe area (the height of the system's own top control).
  static const headerAxis = 44.0;

  /// The chat header row is 56 tall (centre 28); this moves its centre onto [headerAxis].
  static const headerShift = headerAxis - 28;

  /// [headerAxis] for this display: where the system itself puts a navigation title (measured from a standard
  /// navigation bar, in the safe area's coordinates), so the header sits where the system's own bars would, on every
  /// device. [headerAxis] when the platform did not report it.
  double get headerAxisY {
    final title = systemBar?.titleCenterY;
    if (title == null || !hasVerticalBar) return headerAxis;
    return math.max(0.0, title - safe.top);
  }

  double get headerShiftY => headerAxisY - 28;

  /// Width of the chat content column on the unfolded screen with the session list collapsed: the pane is 20% wider
  /// than with the list docked, capped at the full window, and the column is [unfoldedContentFactor] of it.
  static double collapsedColumnWidth(double windowWidth, double sidebarWidth) =>
      math.min(windowWidth, math.max(0.0, windowWidth - sidebarWidth) * 1.2) *
      unfoldedContentFactor;

  /// Same, with the session list docked beside the content: 5% wider than [unfoldedContentFactor].
  static const dockedContentFactor = unfoldedContentFactor * 1.05;
  final DuoBarEdge edge;
  final Size size;
  final EdgeInsets safe;
  final List<DuoRegion> regions;

  /// Where the system's own bar buttons sit in the strip (measured from a standard, invisible navigation bar):
  /// the horizontal center and the vertical centers of the top and bottom button. Our controls line up with these.
  final DuoSystemBar? systemBar;

  /// The system's Reduce Transparency setting: frosted bars should become solid.
  final bool reduceTransparency;

  double get barWidth => switch (edge) {
    DuoBarEdge.right => safe.right,
    DuoBarEdge.left => safe.left,
    DuoBarEdge.none => 0,
  };
  bool get hasVerticalBar => edge != DuoBarEdge.none && barWidth > 0;

  /// The vertical strip below any active occlusion (status bar, Dynamic Island) that overlaps it.
  Rect? get barRect {
    if (!hasVerticalBar) return null;
    final left = edge == DuoBarEdge.right ? size.width - barWidth : 0.0;
    var top = 0.0;
    for (final region in regions) {
      if (region.kind != DuoRegionKind.occlusion || !region.active) continue;
      final overlaps =
          region.rect.right > left + .5 && region.rect.left < left + barWidth;
      if (overlaps) top = math.max(top, region.rect.bottom);
    }
    return Rect.fromLTWH(left, top, barWidth, math.max(0, size.height - top));
  }

  /// A foldable iPhone: the system reports a vertical bar (outer display, inner landscape) or a fold (division)
  /// region, active or not (inner portrait). The outer display has no fold region.
  bool get isFoldable =>
      edge != DuoBarEdge.none ||
      regions.any((r) => r.kind == DuoRegionKind.division);

  /// The active fold as a vertical band (device half-folded in landscape), in screen coordinates. Interactive
  /// controls should stay out of it; scrolling content may cross it. Null when flat or folded horizontally.
  Rect? get verticalFold => _activeFold(vertical: true);

  /// The active fold as a horizontal band (device half-folded in portrait), in screen coordinates. Interactive
  /// controls belong in the half below it and stay off the band. Null when flat or folded vertically.
  Rect? get horizontalFold => _activeFold(vertical: false);

  Rect? _activeFold({required bool vertical}) {
    for (final region in regions) {
      if (region.kind == DuoRegionKind.division &&
          region.active &&
          (vertical
              ? region.rect.height > region.rect.width
              : region.rect.width > region.rect.height)) {
        return region.rect;
      }
    }
    return null;
  }

  /// Half-folded in landscape: the part of the screen right of the fold (inside the safe area), where sheets and
  /// dialogs go so they never straddle the crease. Null when there is no vertical fold or that side is too narrow.
  Rect? get foldPane {
    final fold = verticalFold;
    if (fold == null) return null;
    final pane = Rect.fromLTRB(
      fold.right,
      0,
      size.width - safe.right,
      size.height,
    );
    return pane.width >= 280 ? pane : null;
  }

  /// The part of the window a bottom sheet may use, horizontally: right of a vertical fold, otherwise the window minus
  /// the system's vertical strip (and any side inset in [pad]).
  Rect sheetPane(Size windowSize, EdgeInsets pad) =>
      foldPane ??
      Rect.fromLTRB(
        math.max(pad.left, edge == DuoBarEdge.left ? barWidth : 0),
        0,
        windowSize.width -
            math.max(pad.right, edge == DuoBarEdge.right ? barWidth : 0),
        windowSize.height,
      );

  /// Tallest a bottom sheet may be: [fraction] of the window, and, half-folded in portrait, no taller than the half
  /// below the crease so it never presses over it.
  double sheetMaxHeight(Size windowSize, double fraction) {
    final across = horizontalFold;
    final h = windowSize.height * fraction;
    return across == null
        ? h
        : math.min(h, math.max(240.0, size.height - across.bottom));
  }

  /// Inset for a dialog: the default, or the same margins inside the half that keeps it off the crease when half-folded
  /// (right of a vertical fold, below a horizontal one).
  EdgeInsets dialogInsets([
    EdgeInsets base = const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
  ]) {
    final pane = foldPane, across = horizontalFold;
    if (pane != null) {
      return EdgeInsets.fromLTRB(
        pane.left + base.left,
        base.top,
        size.width - pane.right + base.right,
        base.bottom,
      );
    }
    if (across != null) return base.copyWith(top: across.bottom + base.top);
    return base;
  }

  factory DuoLayout.fromMap(Map<Object?, Object?> map) {
    double number(Object? v) => (v as num?)?.toDouble() ?? 0;
    final safe = map['safe'] as Map<Object?, Object?>? ?? const {};
    return DuoLayout(
      edge: switch (map['edge']) {
        'left' => DuoBarEdge.left,
        'right' => DuoBarEdge.right,
        _ => DuoBarEdge.none,
      },
      reduceTransparency: map['reduceTransparency'] == true,
      size: Size(number(map['width']), number(map['height'])),
      safe: EdgeInsets.fromLTRB(
        number(safe['left']),
        number(safe['top']),
        number(safe['right']),
        number(safe['bottom']),
      ),
      systemBar: switch (map['systemBar']) {
        final Map<Object?, Object?> bar => DuoSystemBar(
          centerX: number(bar['cx']),
          topCenterY: number(bar['top']),
          bottomCenterY: number(bar['bottom']),
          titleCenterY: bar['titleCY'] == null ? null : number(bar['titleCY']),
        ),
        _ => null,
      },
      regions: [
        for (final raw in (map['regions'] as List? ?? const []))
          if (raw is Map)
            DuoRegion(
              kind: raw['kind'] == 'division'
                  ? DuoRegionKind.division
                  : DuoRegionKind.occlusion,
              active: raw['active'] == true,
              rect: Rect.fromLTWH(
                number(raw['x']),
                number(raw['y']),
                number(raw['w']),
                number(raw['h']),
              ),
              margins: EdgeInsets.fromLTRB(
                number(raw['mLeft']),
                number(raw['mTop']),
                number(raw['mRight']),
                number(raw['mBottom']),
              ),
            ),
      ],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DuoLayout &&
      other.edge == edge &&
      other.size == size &&
      other.safe == safe &&
      other.systemBar == systemBar &&
      other.reduceTransparency == reduceTransparency &&
      listEquals(other.regions, regions);
  @override
  int get hashCode => Object.hash(
    edge,
    size,
    safe,
    systemBar,
    reduceTransparency,
    Object.hashAll(regions),
  );
}

/// Native source of [DuoLayout]; only constructed on iOS. Missing native support leaves the layout at [DuoLayout.none].
class ChannelDuoLayoutSource extends ValueNotifier<DuoLayout> {
  ChannelDuoLayoutSource() : super(DuoLayout.none) {
    _sub = _events.receiveBroadcastStream().listen((event) {
      _eventSeen = true;
      _apply(event);
    }, onError: (_) {});
    unawaited(_snapshot());
    // An old native shell never reports; do not hold the app back for it.
    _giveUp = Timer(
      const Duration(milliseconds: 700),
      () => resolved.value = true,
    );
  }

  /// True once the native side has reported the real layout, including the system bar's measured metrics. Until then
  /// [value] is a placeholder, and showing the app would lay it out for a plain phone and then shift it a moment later.
  final resolved = ValueNotifier<bool>(false);
  Timer? _giveUp;
  static const _method = MethodChannel('ai.jarvis.app/duo');
  static const _events = EventChannel('ai.jarvis.app/duo-events');
  StreamSubscription<Object?>? _sub;
  bool _disposed = false;
  bool _eventSeen = false;

  Future<void> _snapshot() async {
    try {
      final raw = await _method.invokeMethod<Object?>('snapshot');
      // The reply can arrive after a newer event (the system bar metrics are measured a moment later); it must not
      // overwrite that with its older, less complete report.
      if (!_eventSeen) _apply(raw);
    } on MissingPluginException {
      // Older native shell: keep the regular layout.
    } on PlatformException {
      // Same: never block the app on a layout hint.
    }
  }

  void _apply(Object? raw) {
    if (_disposed || raw is! Map) return;
    final DuoLayout next;
    try {
      next = DuoLayout.fromMap(raw);
    } catch (_) {
      // A malformed report from native: keep the last layout rather than raising a zone error.
      return;
    }
    value = next;
    if (value.size.width > 0 &&
        (!value.hasVerticalBar || value.systemBar != null)) {
      resolved.value = true;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _giveUp?.cancel();
    resolved.dispose();
    _sub?.cancel();
    super.dispose();
  }
}

class DuoLayoutScope extends InheritedNotifier<ValueListenable<DuoLayout>> {
  const DuoLayoutScope({
    super.key,
    required ValueListenable<DuoLayout> layout,
    required super.child,
  }) : super(notifier: layout);

  static DuoLayout of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DuoLayoutScope>()
          ?.notifier
          ?.value ??
      DuoLayout.none;
}
