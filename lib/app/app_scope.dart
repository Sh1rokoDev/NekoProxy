import 'package:flutter/widgets.dart';

import '../state/app_controller.dart';

class AppScope extends InheritedNotifier<AppController> {
  const AppScope({
    super.key,
    required AppController controller,
    this.onExit,
    required super.child,
  }) : super(notifier: controller);

  final Future<void> Function()? onExit;

  static Future<void> Function()? exitCallback(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()?.onExit;

  static AppController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing');
    return scope!.notifier!;
  }

  static AppController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing');
    return scope!.notifier!;
  }
}

class ShellScope extends InheritedWidget {
  const ShellScope({super.key, required this.switchTab, required super.child});

  final void Function(int index) switchTab;

  static ShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellScope>();

  @override
  bool updateShouldNotify(ShellScope oldWidget) => false;
}
