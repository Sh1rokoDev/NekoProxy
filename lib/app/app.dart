import 'dart:ui';

import 'package:material_ui/material_ui.dart';

import '../state/app_controller.dart';
import 'app_scope.dart';
import 'app_shell.dart';
import 'theme.dart';

class NekoProxyApp extends StatelessWidget {
  const NekoProxyApp({super.key, required this.controller, this.onExit});

  final AppController controller;
  final Future<void> Function()? onExit;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: controller,
      onExit: onExit,
      child: ValueListenableBuilder<int>(
        valueListenable: controller.appearanceTick,
        builder: (context, _, _) {
          final seed = Color(controller.settings.seedColor);
          return MaterialApp(
            title: 'NekoProxy',
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(Brightness.light, seed),
            darkTheme: buildAppTheme(Brightness.dark, seed),
            themeMode: appThemeMode(controller.settings.theme),
            themeAnimationDuration: const Duration(milliseconds: 260),
            scrollBehavior: const _AppScrollBehavior(),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            builder: (context, child) => _ScaledViewport(
              scale: controller.settings.uiScalePercent / 100,
              child: child ?? const SizedBox.shrink(),
            ),
            home: const AppShell(),
          );
        },
      ),
    );
  }
}

class _ScaledViewport extends StatelessWidget {
  const _ScaledViewport({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.of(context);
    final size = window.size / scale;
    return FittedBox(
      fit: BoxFit.fill,
      child: SizedBox.fromSize(
        size: size,
        child: MediaQuery(
          // Layout and input use the same logical viewport, including overlays
          // and safe areas. The system text scaler is kept as supplied.
          data: window.copyWith(
            size: size,
            devicePixelRatio: window.devicePixelRatio * scale,
            padding: window.padding / scale,
            viewPadding: window.viewPadding / scale,
            viewInsets: window.viewInsets / scale,
            systemGestureInsets: window.systemGestureInsets / scale,
            displayFeatures: [
              for (final feature in window.displayFeatures)
                DisplayFeature(
                  bounds: Rect.fromPoints(
                    feature.bounds.topLeft / scale,
                    feature.bounds.bottomRight / scale,
                  ),
                  type: feature.type,
                  state: feature.state,
                ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}
