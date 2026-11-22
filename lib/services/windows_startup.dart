import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

class WindowsStartup {
  WindowsStartup._();

  static const _keyPath = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'NekoProxy';

  static bool get supported => Platform.isWindows;

  static void setEnabled(bool enabled) {
    if (!supported) return;
    final key = CURRENT_USER.open(
      _keyPath,
      config: const RegistryOpenConfig(access: RegistryAccess.readWrite),
    );
    try {
      if (enabled) {
        key.setValue(_valueName, RegistryValue.string(_command));
      } else {
        try {
          key.removeValue(_valueName);
        } catch (_) {
          // Already absent.
        }
      }
    } finally {
      key.close();
    }
  }

  static String get _command => '"${Platform.resolvedExecutable}"';
}
