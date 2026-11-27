import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:material_ui/material_ui.dart';

import '../domain/models.dart';

const appMenuRadius = BorderRadius.all(Radius.circular(8));

ThemeMode appThemeMode(ThemePreference preference) => switch (preference) {
  ThemePreference.system => ThemeMode.system,
  ThemePreference.light => ThemeMode.light,
  ThemePreference.dark => ThemeMode.dark,
};

Color appSurfaceColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFF151719)
    : const Color(0xFFF6F7F8);

ThemeData buildAppTheme(Brightness brightness, Color seed) {
  final dark = brightness == Brightness.dark;
  // The user's accent colors actions and selection; work surfaces stay neutral.
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness)
      .copyWith(
        surface: appSurfaceColor(brightness),
        surfaceContainerLowest: dark ? const Color(0xFF111315) : Colors.white,
        surfaceContainerLow: dark ? const Color(0xFF1C1F22) : Colors.white,
        surfaceContainer: dark
            ? const Color(0xFF232629)
            : const Color(0xFFF0F2F3),
        surfaceContainerHigh: dark
            ? const Color(0xFF282C2F)
            : const Color(0xFFEAEDF0),
        surfaceContainerHighest: dark
            ? const Color(0xFF32373B)
            : const Color(0xFFE2E6E9),
        onSurface: dark ? const Color(0xFFECEEF0) : const Color(0xFF1A2025),
        onSurfaceVariant: dark
            ? const Color(0xFFABB4BC)
            : const Color(0xFF505B65),
        outline: dark ? const Color(0xFF828D96) : const Color(0xFF68737E),
        outlineVariant: dark
            ? const Color(0xFF424A52)
            : const Color(0xFFCCD3D9),
      );
  const controlRadius = BorderRadius.all(Radius.circular(10));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    splashFactory: InkRipple.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _FadeSlidePageTransitionsBuilder(),
        TargetPlatform.windows: _FadeSlidePageTransitionsBuilder(),
        TargetPlatform.linux: _FadeSlidePageTransitionsBuilder(),
        TargetPlatform.macOS: _FadeSlidePageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(fontWeight: FontWeight.w500),
      headlineSmall: TextStyle(fontWeight: FontWeight.w600),
      titleLarge: TextStyle(fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontWeight: FontWeight.w600),
      labelLarge: TextStyle(fontWeight: FontWeight.w600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: controlRadius),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: controlRadius),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: controlRadius),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: controlRadius,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: controlRadius,
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: controlRadius,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide.none,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 3,
      surfaceTintColor: Colors.transparent,
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: appMenuRadius,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.65)),
      ),
      textStyle: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      backgroundColor: scheme.surfaceContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.45),
      space: 1,
    ),
  );
}

class _FadeSlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeSlidePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.035),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
