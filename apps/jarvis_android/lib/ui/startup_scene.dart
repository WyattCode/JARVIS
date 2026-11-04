import 'package:flutter/material.dart';

import 'login_art.dart';

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
        duration: const Duration(milliseconds: 900),
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
              IgnorePointer(
                ignoring: !settled,
                child: ExcludeSemantics(
                  excluding: !settled,
                  child: FadeTransition(
                    opacity: settled
                        ? const AlwaysStoppedAnimation(1.0)
                        : pageOpacity,
                    child: widget.child,
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
                  final rect = Rect.lerp(start, destination ?? start, p)!;
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
