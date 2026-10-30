import 'dart:async';

import 'package:flutter/material.dart';

import 'login_art.dart';
import 'motion.dart';

/// One live reactor is reparented from the launch overlay to its measured slot.
/// Its animation controller and random seed survive the entire handoff.
class StartupGate extends StatefulWidget {
  const StartupGate({super.key, required this.ready, required this.child});
  final bool ready;
  final Widget child;
  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate>
    with SingleTickerProviderStateMixin {
  final stage = GlobalKey(), landing = GlobalKey(), reactor = GlobalKey();
  late final launchProfile = ReactorProfile.random(startup: true);
  Object? destinationIdentity;
  late final flight =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 700),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => landed = true);
        }
      });
  bool landed = false, measuring = false;
  Rect? destination;
  Size? window;
  @override
  void initState() {
    super.initState();
    if (widget.ready) measure();
  }

  @override
  void didUpdateWidget(StartupGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ready && !oldWidget.ready) measure();
    if (!widget.ready && oldWidget.ready) {
      landed = false;
      destination = null;
      flight.reset();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = MediaQuery.sizeOf(context);
    if (window != next && widget.ready && !landed) measure();
    window = next;
  }

  void measure() {
    if (measuring) return;
    measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      measuring = false;
      if (!mounted || !widget.ready || landed) return;
      final target = landing.currentContext?.findRenderObject() as RenderBox?;
      final root = stage.currentContext?.findRenderObject() as RenderBox?;
      if (target != null && root != null && target.hasSize && root.hasSize) {
        destination =
            target.localToGlobal(Offset.zero, ancestor: root) & target.size;
        destinationIdentity = (landing.currentWidget as _LandingBox?)?.identity;
      }
      if (MediaQuery.disableAnimationsOf(context)) {
        setState(() => landed = true);
      } else if (!flight.isAnimating && flight.value == 0) {
        flight.forward();
      }
    });
  }

  @override
  void dispose() {
    flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settled =
        widget.ready && (landed || MediaQuery.disableAnimationsOf(context));
    final pageOpacity = flight.drive(
      CurveTween(curve: const Interval(.12, .82, curve: Curves.easeInOut)),
    );
    return _ReactorScope(
      landing: landing,
      reactor: reactor,
      settled: settled,
      identity: destinationIdentity,
      profile: launchProfile,
      child: ColoredBox(
        color: const Color(0xff09090b),
        child: Stack(
          key: stage,
          fit: StackFit.expand,
          children: [
            if (widget.ready)
              // The page takes touches as soon as it is nearly opaque, not only when the reactor has landed.
              AnimatedBuilder(
                animation: pageOpacity,
                builder: (context, child) => IgnorePointer(
                  ignoring: !settled && pageOpacity.value < .9,
                  child: child,
                ),
                child: ExcludeSemantics(
                  excluding: !settled,
                  child: FadeTransition(
                    opacity: settled
                        ? const AlwaysStoppedAnimation(1.0)
                        : pageOpacity,
                    // Login <-> chat (also when the session expires) cross-fades instead of swapping hard.
                    child: _PageSwitcher(animate: settled, child: widget.child),
                  ),
                ),
              ),
            if (!settled)
              AnimatedBuilder(
                animation: flight,
                builder: (context, child) {
                  final root =
                      stage.currentContext?.findRenderObject() as RenderBox?;
                  final size = root?.hasSize == true
                      ? root!.size
                      : MediaQuery.sizeOf(context);
                  final start = Rect.fromCenter(
                    center: size.center(Offset.zero),
                    width: 176,
                    height: 176,
                  );
                  final p = Curves.easeInOutCubic.transform(flight.value);
                  // The landing box is followed live: the page below can still settle (keyboard, layout updates) while the
                  // reactor flies, and a rectangle measured once would send it to where the box used to be.
                  Rect? live;
                  try {
                    final target =
                        landing.currentContext?.findRenderObject()
                            as RenderBox?;
                    if (root != null &&
                        root.hasSize &&
                        target != null &&
                        target.attached &&
                        target.hasSize) {
                      live =
                          target.localToGlobal(Offset.zero, ancestor: root) &
                          target.size;
                    }
                  } on FlutterError {
                    // The landing box is being replaced; the measured rectangle still applies.
                  }
                  final rect = Rect.lerp(
                    start,
                    live ?? destination ?? start,
                    p,
                  )!;
                  return Positioned.fromRect(
                    rect: rect,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: destination == null && widget.ready
                            ? 1 - p
                            : 1,
                        child: Semantics(
                          label: '贾维斯正在启动',
                          image: true,
                          child: LoginScene(
                            key: reactor,
                            profile: launchProfile,
                            dayBlend:
                                Theme.of(context).brightness == Brightness.light
                                ? p
                                : 0,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Cross-fades between pages that differ by key: the incoming one fades in over the outgoing one, which stays opaque
/// beneath until it is covered, so the background never shows through. While the launch flight is still running
/// (`animate` false) a swap is immediate: the landing box and the reactor keys must never exist in two pages at once.
/// (Not an [AnimatedSwitcher]: it fixes the duration of a page when the page first appears, and the first page appears
/// during the flight, when swapping is still immediate.)
class _PageSwitcher extends StatefulWidget {
  const _PageSwitcher({required this.animate, required this.child});
  final bool animate;
  final Widget child;
  @override
  State<_PageSwitcher> createState() => _PageSwitcherState();
}

class _PageSwitcherState extends State<_PageSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController fade =
      AnimationController(vsync: this, value: 1)..addStatusListener((status) {
        if (status == AnimationStatus.completed && outgoing != null) {
          setState(() => outgoing = null);
        }
      });
  late final Animation<double> incomingOpacity = CurvedAnimation(
    parent: fade,
    curve: Curves.easeOutCubic,
  );
  Widget? outgoing;

  static Object slot(Widget page) => page.key ?? page.runtimeType;

  @override
  void didUpdateWidget(_PageSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (slot(oldWidget.child) == slot(widget.child)) return;
    final duration = widget.animate ? motion(context, 280) : Duration.zero;
    if (duration == Duration.zero) {
      outgoing = null;
      fade.value = 1;
    } else {
      outgoing = oldWidget.child;
      fade.duration = duration;
      unawaited(fade.forward(from: 0));
    }
  }

  @override
  void dispose() {
    fade.dispose();
    super.dispose();
  }

  Widget layer(
    Widget page, {
    required bool inert,
    Animation<double>? opacity,
  }) => KeyedSubtree(
    key: ValueKey(slot(page)),
    child: IgnorePointer(
      ignoring: inert,
      child: ExcludeSemantics(
        excluding: inert,
        child: ExcludeFocus(
          excluding: inert,
          // The same widgets whether the page is coming or going, so a page keeps its state when it changes role.
          child: FadeTransition(
            opacity: opacity ?? const AlwaysStoppedAnimation(1.0),
            child: page,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (outgoing case final page?) layer(page, inert: true),
      layer(
        widget.child,
        inert: false,
        opacity: outgoing == null ? null : incomingOpacity,
      ),
    ],
  );
}

class _ReactorScope extends InheritedWidget {
  const _ReactorScope({
    required this.landing,
    required this.reactor,
    required this.settled,
    required this.identity,
    required this.profile,
    required super.child,
  });
  final GlobalKey landing, reactor;
  final bool settled;
  final Object? identity;
  final ReactorProfile profile;
  @override
  bool updateShouldNotify(_ReactorScope oldWidget) =>
      settled != oldWidget.settled || identity != oldWidget.identity;
}

/// The placeholder participates in real login layout before the flight starts.
class StartupReactorLanding extends StatelessWidget {
  const StartupReactorLanding({super.key, this.identity = 'login'});
  final Object identity;
  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_ReactorScope>();
    // A new conversation after launch gets its own random scene, never the
    // global startup key or a reused animation profile.
    if (scope == null || (scope.settled && scope.identity != identity)) {
      return const LoginScene();
    }
    return _LandingBox(
      key: scope.landing,
      identity: identity,
      child: scope.settled
          ? LoginScene(key: scope.reactor, profile: scope.profile)
          : null,
    );
  }
}

class _LandingBox extends StatelessWidget {
  const _LandingBox({super.key, required this.identity, required this.child});
  final Object identity;
  final Widget? child;
  @override
  Widget build(BuildContext context) => SizedBox.expand(child: child);
}
