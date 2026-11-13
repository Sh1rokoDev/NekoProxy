import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

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
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const AppShell(),
          );
        },
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
