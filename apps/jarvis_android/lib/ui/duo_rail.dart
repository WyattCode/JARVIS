import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart';

import 'action_menu.dart';
import 'call_controls.dart';
import 'duo_layout.dart';

@immutable
class DuoRailAction {
  const DuoRailAction({
    required this.id,
    required this.icon,
    required this.symbol,
    required this.label,
    required this.onPressed,
    this.hangup = false,
  });
  final String id;

  /// Icon for the Flutter fallback (tests, non-iOS).
  final IconData icon;

  /// SF Symbol name used by the native Liquid Glass rail on iOS.
  final String symbol;
  final String label;
  final VoidCallback onPressed;

  /// Render as the end-call button (red).
  final bool hangup;
}

typedef DuoRailSplit = ({
  List<DuoRailAction> top,
  List<DuoRailAction> bottom,
  List<DuoRailAction> overflow,
});

/// While the keyboard is up the strip is short. When every control still fits they stack from the top (the bottom group
/// moves up under the top group); otherwise we keep only the top group plus one overflow menu holding everything else
/// (the bottom group), so nothing sits against the keyboard edge. [extent] is a button plus the [gap] after it; the last
/// button has no gap behind it, so `n` buttons need `n * extent - gap`.
DuoRailSplit splitDuoRailForKeyboard(
  List<DuoRailAction> top,
  List<DuoRailAction> bottom,
  double height, {
  required double extent,
  double gap = 0,
}) {
  final slots = ((height + gap) / extent).floor();
  if (slots <= 0 || (top.isEmpty && bottom.isEmpty)) {
    return (top: const [], bottom: const [], overflow: const []);
  }
  if (top.length + bottom.length <= slots) {
    return (top: [...top, ...bottom], bottom: const [], overflow: const []);
  }
  final keep = math.min(top.length, slots - 1); // one slot is the "..." menu
  return (
    top: top.take(keep).toList(),
    bottom: const [],
    overflow: [...top.skip(keep), ...bottom],
  );
}

/// Which actions fit in a strip of [height]: top and bottom groups keep their order, the rest go into one overflow menu
/// (items overflow from the bottom up, as the system does).
({
  List<DuoRailAction> top,
  List<DuoRailAction> bottom,
  List<DuoRailAction> overflow,
})
splitDuoRail(
  List<DuoRailAction> top,
  List<DuoRailAction> bottom,
  double height, {
  required double extent,
  double gap = 0,
}) {
  final all = [...top, ...bottom];
  if (height + gap >= all.length * extent) {
    return (top: top, bottom: bottom, overflow: const []);
  }
  final slots = ((height + gap) / extent).floor();
  if (slots <= 0) return (top: const [], bottom: const [], overflow: const []);
  // One slot is the overflow button itself.
  final visible = all.take(slots - 1).toSet();
  return (
    top: top.where(visible.contains).toList(),
    bottom: bottom.where(visible.contains).toList(),
    overflow: all.where((a) => !visible.contains(a)).toList(),
  );
}

/// On iPhone Duo the system keeps navigation and toolbar controls in a vertical strip beside the content:
/// top-toolbar buttons at the top of the strip, bottom ones at the bottom, with overflow into a menu. Flutter's own
/// bars are not moved by the system, so this places them there. On iOS the strip is real system UI (Liquid Glass buttons
/// with SF Symbols, see ios/Runner/DuoRailView.swift); elsewhere a plain Flutter version is used. Renders nothing when
/// there is no vertical bar. Must be a child of a [Stack] that covers the whole screen.
class DuoRail extends StatelessWidget {
  const DuoRail({
    super.key,
    this.top = const [],
    this.bottom = const [],
    this.hidden = false,
  }) : _hosted = false,
       _dimBy = null,
       _railKey = null;

  /// The one strip a [DuoRailHost] draws, for the page whose rail is showing; [_dimBy] is a dialog or sheet above
  /// that page, whose barrier the strip takes on (and which keeps its buttons from being pressed).
  const DuoRail._hosted({
    required this.top,
    required this.bottom,
    this._dimBy,
    this._railKey,
  }) : hidden = false,
       _hosted = true;
  final List<DuoRailAction> top, bottom;

  /// Draw nothing (e.g. while the full-screen call page, which has its own rail, is open): a native strip cannot be
  /// covered or faded by Flutter widgets, and VoiceOver would still reach it.
  final bool hidden;
  final bool _hosted;
  final ModalRoute<dynamic>? _dimBy;
  final GlobalKey<_NativeRailState>? _railKey;
  static const extent = 56.0;

  /// Native glass buttons are 48pt with 16pt between them.
  static const nativeButton = 48.0;
  static const nativeExtent = 64.0;
  static const nativeRailWidth = 56.0;

  static bool get native =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// How high the keyboard stood the last time, by window height (so a rotation has its own), and the highest it has got
  /// since it last stood still (where a fall turns). The bottom controls ride the keyboard between the two ends of its
  /// travel.
  static final _lastKeyboard = <int, double>{};
  static double _peak = 0;

  /// Where the keyboard last stood still in the current round (0: not known yet), see [keyboardSettled]; and the latest
  /// height asked about.
  static double _steady = 0, _latest = 0;

  /// The travel the controls were following on the way up (the measured one, or the guess the first time).
  static double _riseTravel = 0;

  /// Where the bottom controls stand between where they rest (1) and where they sit while the keyboard is up (0). It
  /// follows the keyboard's own height, so they come back down exactly as fast as the keyboard goes. The first rise
  /// in a window height has no measured travel and follows a guess; once the keyboard turns, the way down is measured
  /// from the peak it really reached but starts from where the guess left the controls, so they do not jump. A keyboard
  /// that grows and shrinks back while it stays up (text and emoji, the suggestion bar) only moves them once it drops
  /// below where it last stood still.
  static double liftFor(double keyboard, double windowHeight) {
    final key = windowHeight.round();
    _latest = keyboard;
    if (keyboard <= 0) {
      final stood = _steady > 0 ? _steady : _peak;
      if (stood > 0) _lastKeyboard[key] = stood;
      _peak = 0;
      _steady = 0;
      _riseTravel = 0;
      return 1;
    }
    final falling = keyboard < _peak - .5;
    _peak = math.max(_peak, keyboard);
    if (!falling) {
      _riseTravel = _steady > 0
          ? _steady
          : _lastKeyboard[key] ?? windowHeight * .36;
      return (1 - keyboard / _riseTravel).clamp(0.0, 1.0);
    }
    final turned = (1 - _peak / _riseTravel).clamp(0.0, 1.0);
    final from = _steady > 0 ? math.min(_peak, _steady) : _peak;
    final share = math.min(1.0, keyboard / from);
    return (1 - (1 - turned) * share).clamp(0.0, 1.0);
  }

  /// The keyboard has stood still at the height last given to [liftFor]: it is up, at whatever height, so the controls
  /// stand stacked (0), and that height is what the next fall and the next rise are measured against. 1 when it is down.
  static double keyboardSettled() {
    if (_latest <= 0) return 1;
    _steady = _latest;
    _peak = _latest;
    _riseTravel = _latest;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    // Under a host the page only says what its strip holds; the host draws the one strip, which stays put while
    // pages slide (see [DuoRailHost]).
    final host = native && !_hosted ? DuoRailHost._of(context) : null;
    if (host != null) {
      return _RailDeclaration(
        host: host,
        top: top,
        bottom: bottom,
        hidden: hidden,
      );
    }
    final layout = DuoLayoutScope.of(context), strip = layout.barRect;
    if (strip == null || hidden) return const SizedBox.shrink();
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    // Line our buttons up with the system's own bar buttons when the platform reports where they are.
    final bar = native ? layout.systemBar : null;
    const half = nativeButton / 2;
    final left = bar == null ? strip.left : bar.centerX - nativeRailWidth / 2;
    final top0 = bar == null ? strip.top : bar.topCenterY - half;
    final width = bar == null ? strip.width : nativeRailWidth;
    if (native) {
      // One long-lived native strip: with the keyboard up only the set of controls changes (the native view
      // animates it); the strip itself is never resized or replaced.
      final split = keyboard > 0
          ? splitDuoRailForKeyboard(
              top,
              bottom,
              layout.size.height - keyboard - top0,
              extent: nativeExtent,
              gap: nativeExtent - nativeButton,
            )
          : null;
      return Positioned(
        key: const Key('duo-rail'),
        left: left,
        top: top0,
        width: width,
        bottom: bar == null
            ? layout.safe.bottom
            : layout.size.height - (bar.bottomCenterY + half),
        child: _dimmed(
          _NativeRail(
            key: _railKey,
            top: top,
            bottom: bottom,
            fixed: split,
            lift: DuoRail.liftFor(keyboard, layout.size.height),
            keyboard: keyboard,
          ),
        ),
      );
    }
    return Positioned(
      key: const Key('duo-rail'),
      left: left,
      top: top0,
      width: width,
      bottom: math.max(
        keyboard,
        bar == null
            ? layout.safe.bottom
            : layout.size.height - (bar.bottomCenterY + half),
      ),
      child: _RailBody(top: top, bottom: bottom),
    );
  }

  /// Under a dialog or sheet the strip is shaded by that route's barrier as the page around it is, and is not
  /// pressable: in the page it sat under the barrier, above the pages it does not.
  /// The same shape with or without a dialog, so the native view is kept rather than made again.
  Widget _dimmed(Widget rail) {
    if (!_hosted) return rail;
    final route = _dimBy;
    final color = route?.barrierColor;
    final animation = route?.animation;
    return IgnorePointer(
      ignoring: route?.isActive ?? false,
      child: Stack(
        fit: StackFit.expand,
        children: [
          rail,
          IgnorePointer(
            child: color == null || animation == null
                ? const SizedBox.shrink()
                : AnimatedBuilder(
                    animation: animation,
                    builder: (context, _) => ColoredBox(
                      color: color.withValues(
                        alpha: color.a * animation.value.clamp(0.0, 1.0),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The app's routes in order, for [DuoRailHost]: which page is on top and what is above it.
class DuoRailRoutes extends NavigatorObserver with ChangeNotifier {
  final List<Route<dynamic>> routes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
    notifyListeners();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    notifyListeners();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (newRoute != null) {
      i < 0 ? routes.add(newRoute) : routes[i] = newRoute;
    } else if (i >= 0) {
      routes.removeAt(i);
    }
    notifyListeners();
  }
}

/// One strip for the whole app, above its pages, the way the system keeps its own vertical bar: when a page is pushed
/// or popped the strip stays where it is and only its buttons change (the native view animates that), instead of a
/// second native view being made and sliding in with the page, which costs a hitch at the start of every push and a
/// native view to move each frame of it. Pages keep declaring their controls with [DuoRail] / [DuoRailPage]; the
/// strip shows those of the topmost page, from the moment that page is pushed or the page above it is popped.
class DuoRailHost extends StatefulWidget {
  const DuoRailHost({super.key, required this.routes, required this.child});
  final DuoRailRoutes routes;
  final Widget child;

  static _DuoRailHostState? _of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_DuoRailHostScope>()?.host;

  @override
  State<DuoRailHost> createState() => _DuoRailHostState();
}

class _DuoRailHostScope extends InheritedWidget {
  const _DuoRailHostScope({required this.host, required super.child});
  final _DuoRailHostState host;
  @override
  bool updateShouldNotify(_DuoRailHostScope old) => false;
}

/// What one page put in the strip, kept up to date by its [DuoRail] on every build.
class _RailEntry {
  _RailEntry(this.order);
  final int order;
  ModalRoute<dynamic>? route;
  List<DuoRailAction> top = const [], bottom = const [];
  bool hidden = false;

  /// What the strip would show for this entry; the host redraws only when this changes.
  String get signature =>
      '$hidden ${[
        for (final a in [...top, ...bottom]) '${a.id}|${a.symbol}|${a.label}|${a.hangup}',
      ].join(',')} '
      '${top.length}';

  /// Taps go to the page's latest closures, which change with its state, not to the ones of the last redraw.
  void press(String id) {
    for (final a in [...top, ...bottom]) {
      if (a.id == id) return a.onPressed();
    }
  }
}

class _DuoRailHostState extends State<DuoRailHost> {
  final _entries = <_RailEntry>[];
  int _order = 0;
  bool _scheduled = false;
  _RailEntry? _shown;
  ModalRoute<dynamic>? _dimBy, _watched;
  String? _signature;

  @override
  void initState() {
    super.initState();
    widget.routes.addListener(_routesChanged);
  }

  @override
  void didUpdateWidget(DuoRailHost old) {
    super.didUpdateWidget(old);
    if (old.routes != widget.routes) {
      old.routes.removeListener(_routesChanged);
      widget.routes.addListener(_routesChanged);
    }
  }

  @override
  void dispose() {
    widget.routes.removeListener(_routesChanged);
    super.dispose();
  }

  _RailEntry _add() {
    final entry = _RailEntry(_order++);
    _entries.add(entry);
    return entry;
  }

  void _remove(_RailEntry entry) {
    _entries.remove(entry);
    _changed();
  }

  /// Worked out after the frame: pages declare while they build, and a pushed page builds in the frame after the push,
  /// so by then its controls are known and the strip never shows nothing in between.
  void _changed() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _scheduled = false;
        if (mounted) _pick();
      })
      ..ensureVisualUpdate();
  }

  /// A pop hands the strip back before the pop's first frame: the page underneath has its controls already. A push
  /// waits for the pushed page's first frame (laid out offstage, nothing moves yet), when its controls are known.
  void _routesChanged() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if ((phase == SchedulerPhase.idle ||
            phase == SchedulerPhase.postFrameCallbacks) &&
        _pick(onlyIfShown: true)) {
      return;
    }
    _changed();
  }

  /// The strip's controls, forwarded to the page's latest closures.
  List<DuoRailAction> _top = const [], _bottom = const [];

  /// The native view behind the strip, told about a new set of controls straight away (see [_NativeRailState.showNow]).
  final _railKey = GlobalKey<_NativeRailState>();

  bool _pick({bool onlyIfShown = false}) {
    _RailEntry? latest(Iterable<_RailEntry> entries) => entries.isEmpty
        ? null
        : entries.reduce((a, b) => a.order > b.order ? a : b);
    _RailEntry? shown;
    ModalRoute<dynamic>? dimBy;
    final routes = widget.routes.routes;
    if (routes.isEmpty) {
      // Not told about routes (no observer): the latest page that is still there.
      shown = latest(_entries.where((e) => e.route?.isActive ?? true));
    } else {
      // The topmost page decides, from the moment it is pushed until it is popped; dialogs, sheets and menus above it
      // leave its controls in place, shaded. A page without controls (a full-screen preview) shows none.
      for (final route in routes.reversed) {
        if (!route.isActive) continue;
        if (route is PopupRoute) {
          dimBy ??= route;
          continue;
        }
        shown = latest(_entries.where((e) => e.route == route));
        break;
      }
    }
    // A dialog being closed fades its barrier out: the strip's shade goes with it (the buttons work again at once).
    final closing = _dimBy;
    if (dimBy == null &&
        closing != null &&
        !closing.isActive &&
        !(closing.animation?.isDismissed ?? true)) {
      dimBy = closing;
      if (_watched != closing) {
        _watched = closing;
        void done(AnimationStatus status) {
          if (status != AnimationStatus.dismissed) return;
          closing.animation?.removeStatusListener(done);
          if (_watched == closing) _watched = null;
          if (mounted) _changed();
        }

        closing.animation?.addStatusListener(done);
      }
    }
    if (onlyIfShown && shown == null) return false;
    final signature = shown == null
        ? null
        : '${shown.order} ${shown.signature} ${identityHashCode(dimBy)} '
              '${dimBy?.isActive}';
    if (signature == _signature) return true;
    final entry = shown;
    setState(() {
      _shown = shown;
      _dimBy = dimBy;
      _signature = signature;
      _top = [for (final a in entry?.top ?? const []) _forward(entry!, a)];
      _bottom = [
        for (final a in entry?.bottom ?? const []) _forward(entry!, a),
      ];
    });
    if (entry != null && !entry.hidden) {
      _railKey.currentState?.showNow(_top, _bottom);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final entry = _shown;
    return _DuoRailHostScope(
      host: this,
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          if (entry != null && !entry.hidden)
            Positioned.fill(
              child: Stack(
                children: [
                  DuoRail._hosted(
                    top: _top,
                    bottom: _bottom,
                    dimBy: _dimBy,
                    railKey: _railKey,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  DuoRailAction _forward(_RailEntry entry, DuoRailAction a) => DuoRailAction(
    id: a.id,
    icon: a.icon,
    symbol: a.symbol,
    label: a.label,
    hangup: a.hangup,
    onPressed: () => entry.press(a.id),
  );
}

/// A page's [DuoRail] under a [DuoRailHost]: it draws nothing itself and keeps the host told what the page's strip
/// holds.
class _RailDeclaration extends StatefulWidget {
  const _RailDeclaration({
    required this.host,
    required this.top,
    required this.bottom,
    required this.hidden,
  });
  final _DuoRailHostState host;
  final List<DuoRailAction> top, bottom;
  final bool hidden;
  @override
  State<_RailDeclaration> createState() => _RailDeclarationState();
}

class _RailDeclarationState extends State<_RailDeclaration> {
  late final _RailEntry entry = widget.host._add();

  @override
  void dispose() {
    widget.host._remove(entry);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    entry
      ..route = ModalRoute.of(context)
      ..top = widget.top
      ..bottom = widget.bottom
      ..hidden = widget.hidden;
    widget.host._changed();
    return const SizedBox.shrink();
  }
}

class _NativeRail extends StatefulWidget {
  const _NativeRail({
    super.key,
    required this.top,
    required this.bottom,
    this.fixed,
    this.lift = 1,
    this.keyboard = 0,
  });
  final List<DuoRailAction> top, bottom;

  /// See [DuoRail.liftFor].
  final double lift;

  /// The keyboard height [lift] was worked out for: once it stops changing the keyboard stands still.
  final double keyboard;

  /// A precomputed split (keyboard up); otherwise fitted to the available height.
  final DuoRailSplit? fixed;
  @override
  State<_NativeRail> createState() => _NativeRailState();
}

class _NativeRailState extends State<_NativeRail> {
  /// Always the latest closures, so a tap never runs stale state.
  final handlers = <String, VoidCallback>{};

  /// The channel of the current native view; a recreated view gets a new id, so the previous handler is released.
  MethodChannel? _channel;

  /// What the native view currently shows (creation params, then each `update`).
  String? _shown;
  Map<String, Object?>? _pending;

  /// The lift the native view was last given, and the last one this widget was built with.
  double _lifted = 1;
  double? _asked;

  /// Fires once the keyboard has kept its height for a moment (see [DuoRail.keyboardSettled]).
  Timer? _settle;
  double _keyboardSeen = 0;

  void _sendLift(double value) {
    _lifted = value;
    // Straight after the frame, with no animation of its own: the keyboard is the clock.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _channel?.invokeMethod<void>('lift', value).catchError((Object _) {});
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _pending = null;
    super.dispose();
  }

  void _flush() {
    final params = _pending, channel = _channel;
    if (params == null || channel == null) return;
    _pending = null;
    channel.invokeMethod<void>('update', params).catchError((Object _) {});
  }

  Map<String, Object?> item(DuoRailAction a) => {
    'id': a.id,
    'symbol': a.symbol,
    'label': a.label,
    if (a.hangup) 'destructive': true,
  };

  /// The height the strip was last laid out at.
  double? _height;

  Map<String, Object?> _params(DuoRailSplit split, List<DuoRailAction> bottom) {
    final all = [...split.top, ...split.bottom, ...split.overflow];
    handlers
      ..clear()
      ..addEntries(all.map((a) => MapEntry(a.id, a.onPressed)));
    return {
      'dark': Theme.of(context).brightness == Brightness.dark,
      'top': split.top.map(item).toList(),
      'bottom': split.bottom.map(item).toList(),
      'overflow': split.overflow.map(item).toList(),
      // The controls that rest at the bottom: while the keyboard is up some of them stand with the top group.
      'rest': bottom.map((a) => a.id).toList(),
    };
  }

  /// Gives the native view a new set of controls now, outside any frame. Switching them costs the main thread a
  /// dozen milliseconds or more, and Flutter's frames run on that thread too: done in the middle of a page's slide it
  /// drops frames, done before the slide has put anything on screen it only starts the slide that much later. The
  /// build that follows finds the same set and sends nothing. With the keyboard up the split depends on it, so that
  /// case is left to the build.
  void showNow(List<DuoRailAction> top, List<DuoRailAction> bottom) {
    final height = _height, channel = _channel;
    if (!mounted || height == null || channel == null || widget.fixed != null) {
      return;
    }
    final split = splitDuoRail(
      top,
      bottom,
      height,
      extent: DuoRail.nativeExtent,
      gap: DuoRail.nativeExtent - DuoRail.nativeButton,
    );
    final params = _params(split, bottom);
    final signature = params.toString();
    if (signature == _shown) return;
    _shown = signature;
    _pending = null;
    channel.invokeMethod<void>('update', params).catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      _height = bounds.maxHeight;
      final split =
          widget.fixed ??
          splitDuoRail(
            widget.top,
            widget.bottom,
            bounds.maxHeight,
            extent: DuoRail.nativeExtent,
            gap: DuoRail.nativeExtent - DuoRail.nativeButton,
          );
      final params = _params(split, widget.bottom);
      final signature = params.toString();
      if (_shown == null) {
        _shown = signature;
      } else if (signature != _shown) {
        _shown = signature;
        _pending = params;
        // The native view animates to the new set of controls.
        WidgetsBinding.instance.addPostFrameCallback((_) => _flush());
      }
      // The first lift goes with the creation params; a rail made while the keyboard is up starts lifted.
      _asked ??= _lifted = widget.lift;
      if ((widget.lift - _asked!).abs() > .0005) {
        _asked = widget.lift;
        if ((widget.lift - _lifted).abs() > .0005) _sendLift(widget.lift);
      }
      if (widget.keyboard != _keyboardSeen) {
        _keyboardSeen = widget.keyboard;
        _settle?.cancel();
        _settle = widget.keyboard <= 0
            ? null
            : Timer(const Duration(milliseconds: 200), () {
                // Up and still, at whatever height: the controls stand stacked, not part of the way down.
                final value = DuoRail.keyboardSettled();
                if (!mounted || (value - _lifted).abs() <= .0005) return;
                _lifted = value;
                _channel
                    ?.invokeMethod<void>('lift', value)
                    .catchError((Object _) {});
              });
      }
      // A tap on the strip is not "outside" the composer: it would hide the keyboard, the strip would then regain its
      // full set of controls and the overflow menu that was just opened would vanish under the finger.
      return TextFieldTapRegion(
        child: UiKitView(
          viewType: 'ai.jarvis.app/duo-rail',
          // Not part of `params`: the lift changes every keyboard frame and must not count as a new set of controls.
          creationParams: {...params, 'lift': _lifted},
          creationParamsCodec: const StandardMessageCodec(),
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          onPlatformViewCreated: (id) {
            _channel?.setMethodCallHandler(null);
            _channel = MethodChannel('ai.jarvis.app/duo-rail/$id')
              ..setMethodCallHandler((call) async {
                if (call.method == 'tap') {
                  handlers[call.arguments as String]?.call();
                }
              });
            _flush();
            // A lift sent while the view was still being made went nowhere.
            _channel
                ?.invokeMethod<void>('lift', _lifted)
                .catchError((Object _) {});
          },
        ),
      );
    },
  );
}

class _RailBody extends StatelessWidget {
  const _RailBody({required this.top, required this.bottom});
  final List<DuoRailAction> top, bottom;

  Widget button(DuoRailAction action) => action.hangup
      ? SizedBox.square(
          dimension: DuoRail.extent,
          child: Center(
            child: HangupButton(
              key: Key('duo-rail-${action.id}'),
              onPressed: action.onPressed,
            ),
          ),
        )
      : IconButton(
          key: Key('duo-rail-${action.id}'),
          tooltip: action.label,
          onPressed: action.onPressed,
          constraints: const BoxConstraints.tightFor(
            width: DuoRail.extent,
            height: DuoRail.extent,
          ),
          icon: Icon(action.icon, size: 22),
        );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final split = splitDuoRail(
        top,
        bottom,
        bounds.maxHeight,
        extent: DuoRail.extent,
      );
      if (split.overflow.isEmpty) {
        return Column(
          children: [
            ...split.top.map(button),
            const Spacer(),
            ...split.bottom.map(button),
          ],
        );
      }
      // Not enough height (keyboard up): keep the first controls, move the rest into one overflow menu.
      if (bounds.maxHeight < DuoRail.extent) return const SizedBox.shrink();
      return Column(
        children: [
          ...[...split.top, ...split.bottom].map(button),
          JarvisActionMenu(
            key: const Key('duo-rail-overflow'),
            tooltip: '更多操作',
            actions: [
              for (final a in split.overflow)
                JarvisMenuAction(a.id, a.label, icon: a.icon),
            ],
            onSelected: (id) =>
                split.overflow.firstWhere((a) => a.id == id).onPressed(),
          ),
        ],
      );
    },
  );
}

/// A pushed page with its own rail (back/close at the top of the strip).
class DuoRailPage extends StatelessWidget {
  const DuoRailPage({
    super.key,
    required this.child,
    this.top = const [],
    this.bottom = const [],
  });
  final Widget child;
  final List<DuoRailAction> top, bottom;

  /// True when the page should drop its own back button because the rail carries it.
  static bool active(BuildContext context) =>
      DuoLayoutScope.of(context).hasVerticalBar;

  static DuoRailAction back(BuildContext context) => DuoRailAction(
    id: 'back',
    icon: Icons.arrow_back,
    symbol: 'chevron.backward',
    label: '返回',
    onPressed: () => Navigator.of(context).maybePop(),
  );

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: child),
      DuoRail(top: top, bottom: bottom),
    ],
  );
}

/// Foldable iPhone: scrolling content runs to the physical bottom edge (under the home-indicator inset) and fades out
/// softly, instead of being clipped by the safe area into a hard edge with a dead band below it. Pair it with
/// `SafeArea(bottom: !SoftBottomEdge.active(context))` and [SoftBottomEdge.inset] as extra bottom padding.
class SoftBottomEdge extends StatelessWidget {
  const SoftBottomEdge({
    super.key,
    required this.child,
    this.keyboardUp = false,
  });
  final Widget child;

  /// Whether the keyboard is showing. Read by the caller *outside* the page's Scaffold, because the Scaffold consumes
  /// the keyboard inset for its body.
  final bool keyboardUp;

  /// The keyboard state to pass in, read from the page's own (outer) context.
  static bool keyboardShown(BuildContext context) =>
      MediaQuery.viewInsetsOf(context).bottom > 0;

  /// Foldable iPhones and every other iPhone with a home indicator: the page runs to the screen edge and fades out
  /// softly instead of being cut off at the safe area.
  static bool active(BuildContext context) =>
      DuoLayoutScope.of(context).isFoldable ||
      (!kIsWeb &&
          defaultTargetPlatform == TargetPlatform.iOS &&
          MediaQuery.viewPaddingOf(context).bottom > 0);

  /// Extra bottom padding the scrolling content needs so its last row can scroll clear of the home indicator.
  static double inset(BuildContext context) =>
      active(context) && MediaQuery.viewInsetsOf(context).bottom == 0
      ? MediaQuery.viewPaddingOf(context).bottom
      : 0;

  @override
  Widget build(BuildContext context) {
    // With the keyboard up the content already ends at the keyboard: no fade over it, no extra inset.
    if (!active(context) || keyboardUp) return child;
    final background = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          key: const Key('soft-bottom-edge'),
          left: 0,
          right: 0,
          bottom: 0,
          height: MediaQuery.viewPaddingOf(context).bottom + 24,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [background.withValues(alpha: 0), background],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
