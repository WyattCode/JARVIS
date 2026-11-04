import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'net/jarvis_api.dart';
import 'state/jarvis_controller.dart';
import 'state/vault.dart';
import 'state/blobs.dart';
import 'ui/jarvis_app.dart';
import 'ui/startup_scene.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const server = String.fromEnvironment(
    'JARVIS_SERVER',
    defaultValue: 'https://jarvis.odn.cc',
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
  const JarvisApp({super.key, required this.controller});
  final JarvisController controller;
  @override
  State<JarvisApp> createState() => _JarvisAppState();
}

class _JarvisAppState extends State<JarvisApp> with WidgetsBindingObserver {
  final navigator = GlobalKey<NavigatorState>();
  late final lightTheme = _theme(Brightness.light);
  late final darkTheme = _theme(Brightness.dark);
  late Object shellState;
  Object readShellState() {
    final c = widget.controller;
    return (
      c.initialized,
      c.authenticated,
      c.theme,
      c.authenticated ? false : c.connecting,
      c.authenticated ? null : c.error,
    );
  }

  bool _lastAuthenticated = false;
  void authChanged() {
    final authenticated = widget.controller.authenticated;
    if (_lastAuthenticated && !authenticated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.controller.authenticated) {
          navigator.currentState?.popUntil((route) => route.isFirst);
        }
      });
    }
    _lastAuthenticated = authenticated;
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
    widget.controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (widget.controller.voice.held) widget.controller.voice.cancelHold();
      widget.controller.save();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(authChanged);
    widget.controller.dispose();
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

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    debugShowCheckedModeBanner: false,
    title: 'JARVIS',
    theme: lightTheme,
    darkTheme: darkTheme,
    themeMode: switch (widget.controller.theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    },
    locale: const Locale('zh'),
    supportedLocales: const [Locale('zh'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: StartupGate(
      ready: widget.controller.initialized,
      child: widget.controller.authenticated
          ? JarvisHome(controller: widget.controller)
          : LoginPage(controller: widget.controller),
    ),
  );
}
