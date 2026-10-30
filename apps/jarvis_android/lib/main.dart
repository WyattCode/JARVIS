import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_localizations/flutter_localizations.dart';

import 'net/jarvis_api.dart';
import 'state/jarvis_controller.dart';
import 'state/system_settings.dart';
import 'state/vault.dart';
import 'state/blobs.dart';
import 'ui/duo_layout.dart';
import 'ui/duo_rail.dart' show DuoRailHost, DuoRailRoutes;
import 'ui/jarvis_app.dart';
import 'ui/rotation_dissolve.dart';
import 'ui/startup_scene.dart';

/// Largest system text scale the layouts are verified for (iOS AX3, 2.4x).
const maxSystemTextScale = 2.4;

/// How long a saved session may be checked before the launch scene hands over to the local (offline) session instead of
/// waiting any longer; a slow mobile network can take 20 to 30 seconds to answer.
const signInGrace = Duration(seconds: 9);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const server = String.fromEnvironment(
    'JARVIS_SERVER',
    defaultValue: 'https://jarvis.example.com',
  );
  runApp(
    JarvisApp(
      controller: JarvisController(
        JarvisApi(Uri.parse(server)),
        NativeVault(),
        blobs: NativeBlobs(),
      ),
    ),
  );
}

class JarvisApp extends StatefulWidget {
  const JarvisApp({super.key, required this.controller, this.duoLayout});
  final JarvisController controller;

  /// iPhone Duo layout facts; defaults to the native channel on iOS and to none elsewhere.
  final ValueListenable<DuoLayout>? duoLayout;
  @override
  State<JarvisApp> createState() => _JarvisAppState();
}

class _JarvisAppState extends State<JarvisApp> with WidgetsBindingObserver {
  final navigator = GlobalKey<NavigatorState>();

  /// The routes the one Duo strip follows (see [DuoRailHost]).
  final railRoutes = DuoRailRoutes();
  late final ValueListenable<DuoLayout>? duoLayout =
      widget.duoLayout ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
          ? ChannelDuoLayoutSource()
          : null);
  late final lightTheme = _theme(Brightness.light);
  late final darkTheme = _theme(Brightness.dark);
  late Object shellState;
  Object readShellState() {
    final c = widget.controller;
    return (
      c.initialized,
      c.authenticated,
      c.offlineSession,
      c.theme,
      c.authenticated ? false : c.connecting,
      c.authenticated ? null : c.error,
    );
  }

  /// The chat shows rather than the login page: signed in, offline on a saved session, or still checking it at launch.
  bool get sessionKept =>
      widget.controller.authenticated ||
      widget.controller.offlineSession ||
      launchCheck;

  bool _lastKept = false;
  void authChanged() {
    trackLaunchCheck();
    final kept = sessionKept;
    // Leaving the chat by any road (signing out of an offline or launch-check session too) takes the pages over it along.
    if (_lastKept && !kept) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !sessionKept) {
          navigator.currentState?.popUntil((route) => route.isFirst);
        }
      });
    }
    _lastKept = kept;
    // Chat/PCM events update their own listeners, not the application router.
    final next = readShellState();
    if (next != shellState && mounted) {
      setState(() => shellState = next);
    }
  }

  @override
  void initState() {
    super.initState();
    shellState = readShellState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(authChanged);
    if (duoLayout case final ChannelDuoLayoutSource source) {
      source.resolved.addListener(duoResolved);
    }
    signInTimer = Timer(signInGrace, () {
      if (mounted) setState(() => signInWaitOver = true);
    });
    widget.controller.initialize();
  }

  /// The startup waits for the real Duo layout, so the first screen is laid out once instead of shifting.
  bool get duoReady => switch (duoLayout) {
    final ChannelDuoLayoutSource source => source.resolved.value,
    _ => true,
  };

  /// A saved session is being checked: stay on the launch scene instead of flashing the login page and then switching to
  /// the chat. Gives up after a few seconds (slow network), when the login page with its message is the honest answer.
  bool signInWaitOver = false;
  Timer? signInTimer;
  bool get signingIn =>
      widget.controller.connecting &&
      !widget.controller.authenticated &&
      !signInWaitOver;

  /// Once the launch scene has handed over it stays handed over: a login attempt (`connecting`) from the login page must
  /// not count as "checking a saved session" and replay the launch flight over the page.
  bool gateOpened = false;
  bool get gateReady => gateOpened =
      gateOpened || (widget.controller.initialized && duoReady && !signingIn);

  /// The saved session found at launch is still being checked (the service is slow to answer). Once the grace is over
  /// the app opens the local history in its offline state, which turns into the signed-in one when the check succeeds
  /// and into the login page only if the session is rejected. A login typed on the login page never counts: by then the
  /// launch scene has already handed over.
  bool launchCheck = false;
  void trackLaunchCheck() {
    final c = widget.controller;
    if (!c.connecting) {
      launchCheck = false;
    } else if (!gateOpened &&
        c.initialized &&
        !c.authenticated &&
        c.api.cookie != null) {
      launchCheck = true;
    }
  }

  void duoResolved() {
    if (mounted) setState(() {});
  }

  /// The system's Reduce Motion switch (not visible to the app's own theme, which sits above its MediaQuery).
  bool get reduceMotion => WidgetsBinding
      .instance
      .platformDispatcher
      .accessibilityFeatures
      .disableAnimations;

  @override
  void didChangeAccessibilityFeatures() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (widget.controller.voice.held) widget.controller.voice.cancelHold();
      unawaited(widget.controller.saveIfDirty());
    } else if (state == AppLifecycleState.resumed) {
      // A saved session that could not be reached at launch (or since) gets another try now.
      widget.controller.appResumed();
    }
  }

  @override
  void dispose() {
    signInTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(authChanged);
    widget.controller.dispose();
    if (duoLayout case final ChannelDuoLayoutSource source) {
      source.resolved.removeListener(duoResolved);
      if (widget.duoLayout == null) source.dispose();
    }
    railRoutes.dispose();
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors =
        ColorScheme.fromSeed(
          seedColor: const Color(0xff3e899b),
          brightness: brightness,
        ).copyWith(
          surface: dark ? const Color(0xff09090b) : const Color(0xfff9faf9),
          primary: dark ? const Color(0xffd5d5df) : const Color(0xff28596a),
          surfaceContainerLowest: dark
              ? const Color(0xff09090b)
              : const Color(0xffffffff),
          surfaceContainerLow: dark
              ? const Color(0xff121214)
              : const Color(0xffffffff),
          surfaceContainer: dark
              ? const Color(0xff18181b)
              : const Color(0xfff1f3f2),
          surfaceContainerHigh: dark
              ? const Color(0xff1c1c20)
              : const Color(0xffedf0ef),
          surfaceContainerHighest: dark
              ? const Color(0xff242429)
              : const Color(0xffe8edeb),
          onSurface: dark ? const Color(0xffededf1) : null,
          onSurfaceVariant: dark ? const Color(0xffa1a1aa) : null,
          onPrimary: dark ? const Color(0xff161619) : null,
          // Neutral surfaces match src/voice/auth/theme.css; cyan stays an accent.
          secondary: dark ? const Color(0xffa8deeb) : null,
          onSecondary: dark ? const Color(0xff121214) : null,
          tertiary: dark ? const Color(0xff8ed4e5) : null,
          onTertiary: dark ? const Color(0xff121214) : null,
          error: dark ? const Color(0xffff9b8c) : null,
          errorContainer: dark ? const Color(0xff382c30) : null,
          onErrorContainer: dark ? const Color(0xffffc0b1) : null,
          inverseSurface: dark ? const Color(0xffededf1) : null,
          onInverseSurface: dark ? const Color(0xff25252a) : null,
          inversePrimary: dark ? const Color(0xff287a90) : null,
          scrim: dark ? Colors.black : null,
          primaryContainer: dark
              ? const Color(0xff242429)
              : const Color(0xffe7eeec),
          onPrimaryContainer: dark
              ? const Color(0xffededf1)
              : const Color(0xff24454c),
          secondaryContainer: dark
              ? const Color(0xff1c1c20)
              : const Color(0xffe8edeb),
          onSecondaryContainer: dark
              ? const Color(0xffededf1)
              : const Color(0xff24454c),
          surfaceTint: dark ? Colors.transparent : null,
          outline: dark ? const Color(0xff36363d) : null,
          outlineVariant: dark
              ? const Color(0xff303036)
              : const Color(0xffdce3e1),
        );
    final text = ThemeData(useMaterial3: true, colorScheme: colors).textTheme;
    return ThemeData(
      useMaterial3: true,
      // iOS has no ink ripple: a pressed control shows its pressed overlay colour only.
      splashFactory: defaultTargetPlatform == TargetPlatform.iOS
          ? NoSplash.splashFactory
          : null,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.iOS: _MotionAwarePageTransitions()},
      ),
      textTheme: text.copyWith(
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        bodyLarge: text.bodyLarge?.copyWith(height: 1.5),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.5),
        bodySmall: text.bodySmall?.copyWith(height: 1.45),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: .6),
        thickness: .7,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surfaceContainerHigh,
        contentTextStyle: text.bodyMedium?.copyWith(color: colors.onSurface),
        actionTextColor: colors.primary,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
      cardTheme: CardThemeData(
        color: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .7)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dialogTheme: DialogThemeData(
        barrierColor: dark ? Colors.black.withValues(alpha: .65) : null,
        backgroundColor: colors.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        // Semibold like the app's other headings (titleLarge), not Material's regular 24pt dialog headline.
        titleTextStyle: text.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          height: 1.35,
          color: colors.onSurface,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        modalBarrierColor: dark ? Colors.black.withValues(alpha: .65) : null,
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        scrolledUnderElevation: 0,
        titleTextStyle: text.titleMedium?.copyWith(
          color: colors.onSurface,
          fontWeight: FontWeight.w600,
        ),
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: colors.onSurface, size: 20),
      ),
      iconTheme: IconThemeData(color: colors.onSurfaceVariant, size: 20),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
        ),
      ),
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(
          iconSize: WidgetStatePropertyAll(20),
          minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        ),
      ),
    );
  }

  static const _appearance = MethodChannel('ai.jarvis.app/appearance');
  String? _appearanceSent;

  /// The window follows the app's own light or dark choice (not only the system's), so what shows wherever Flutter has not
  /// drawn (a rotation, the status bar, the keyboard) is never the other theme's colour.
  void _syncAppearance(String theme) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        _appearanceSent == theme) {
      return;
    }
    _appearanceSent = theme;
    unawaited(
      _appearance.invokeMethod<void>('set', theme).catchError((Object _) {
        // Not applied (the window was not attached yet, say): the next build sends it again.
        if (_appearanceSent == theme) _appearanceSent = null;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    trackLaunchCheck();
    _syncAppearance(widget.controller.theme);
    return MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [railRoutes],
      debugShowCheckedModeBanner: false,
      title: 'JARVIS',
      theme: lightTheme,
      darkTheme: darkTheme,
      // Reduce Motion: a theme switch is instant.
      themeAnimationDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 200),
      themeMode: switch (widget.controller.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // Android's system maximum is ~2.0x; iOS accessibility sizes reach ~3.1x
      // and break the fixed-height header and composer toolbar.
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        final clamped = defaultTargetPlatform == TargetPlatform.iOS
            ? MediaQuery.withClampedTextScaling(
                maxScaleFactor: maxSystemTextScale,
                child: content,
              )
            : content;
        final duo = duoLayout;
        // One strip above every page: it stays put while pages slide and only its buttons change.
        final dissolving = RotationDissolve(
          child: DuoRailHost(routes: railRoutes, child: clamped),
        );
        return duo == null
            ? dissolving
            : DuoLayoutScope(layout: duo, child: dissolving);
      },
      home: StartupGate(
        ready: gateReady,
        // A saved session the service could not be reached for still opens the local history (sending is off) rather
        // than the login page; only a rejected session or no session at all shows the login.
        child: sessionKept
            ? JarvisHome(
                key: const ValueKey('chat'),
                controller: widget.controller,
                onCancelTask: (task) =>
                    unawaited(widget.controller.cancelMediaTask(task)),
                openSettings: openAppSettings,
                // A reply cut off at the length limit carries on where it stopped.
                onContinue: () => unawaited(widget.controller.continueReply()),
                offline: () => widget.controller.offlineSession || launchCheck,
                onRetry: () => unawaited(widget.controller.retryConnect()),
              )
            : LoginPage(
                key: const ValueKey('login'),
                controller: widget.controller,
              ),
      ),
    );
  }
}

/// iOS page transitions: the usual slide (with the swipe-back gesture), or a plain fade when the system reduces motion.
class _MotionAwarePageTransitions extends PageTransitionsBuilder {
  const _MotionAwarePageTransitions();
  static const _slide = CupertinoPageTransitionsBuilder();
  static bool get _reduced => WidgetsBinding
      .instance
      .platformDispatcher
      .accessibilityFeatures
      .disableAnimations;

  @override
  Duration get transitionDuration =>
      _reduced ? const Duration(milliseconds: 200) : _slide.transitionDuration;

  // The page underneath stays put instead of sliding along.
  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _reduced ? null : _slide.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _reduced || MediaQuery.disableAnimationsOf(context)
      ? FadeTransition(opacity: animation, child: child)
      : _slide.buildTransitions<T>(
          route,
          context,
          animation,
          secondaryAnimation,
          child,
        );
}
