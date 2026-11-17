import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';

import '../data/app_storage.dart';

class SystemProxySnapshot {
  const SystemProxySnapshot({
    this.proxyEnable,
    this.proxyServer,
    this.proxyOverride,
    this.autoConfigUrl,
    this.appliedServer,
  });

  final int? proxyEnable;
  final String? proxyServer;
  final String? proxyOverride;
  final String? autoConfigUrl;
  final String? appliedServer;

  SystemProxySnapshot withAppliedServer(String server) => SystemProxySnapshot(
        proxyEnable: proxyEnable,
        proxyServer: proxyServer,
        proxyOverride: proxyOverride,
        autoConfigUrl: autoConfigUrl,
        appliedServer: server,
      );

  Map<String, dynamic> toJson() => {
        'proxyEnable': proxyEnable,
        'proxyServer': proxyServer,
        'proxyOverride': proxyOverride,
        'autoConfigUrl': autoConfigUrl,
        'appliedServer': appliedServer,
      };

  factory SystemProxySnapshot.fromJson(Map<String, dynamic> json) => SystemProxySnapshot(
        proxyEnable: (json['proxyEnable'] as num?)?.toInt(),
        proxyServer: json['proxyServer'] as String?,
        proxyOverride: json['proxyOverride'] as String?,
        autoConfigUrl: json['autoConfigUrl'] as String?,
        appliedServer: json['appliedServer'] as String?,
      );
}

class ProxyApplyResult {
  const ProxyApplyResult({required this.ok, this.error});
  final bool ok;
  final String? error;
}

class WindowsSystemProxy {
  WindowsSystemProxy(this.paths);

  static const _internetSettings = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const _refresh = 37;
  static const _settingsChanged = 39;
  final AppPaths paths;
  String? _server;

  bool get supported => Platform.isWindows;

  ProxyApplyResult enable(int port) {
    if (!supported) return const ProxyApplyResult(ok: false, error: '仅 Windows 支持系统代理');
    try {
      final key = _openSettings();
      try {
        final existing = _readSnapshot(key);
        final owned = File(paths.proxySnapshotFile.path);
        final existingOwned = owned.existsSync()
            ? SystemProxySnapshot.fromJson(
                Map<String, dynamic>.from(jsonDecode(owned.readAsStringSync()) as Map),
              )
            : null;
        final original = existingOwned ?? existing;
        _server = '127.0.0.1:$port';
        owned.writeAsStringSync(
          jsonEncode(original.withAppliedServer(_server!).toJson()),
          flush: true,
        );
        if (existing.autoConfigUrl != null) {
          _removeValue(key, 'AutoConfigURL');
        }
        key.setValue('ProxyEnable', const RegistryValue.dword(1));
        key.setValue('ProxyServer', RegistryValue.string(_server!));
        // Let sing-box rules decide how to route LAN destinations. Only
        // loopback is excluded from the Windows proxy itself.
        key.setValue(
          'ProxyOverride',
          const RegistryValue.string('localhost;127.*;[::1]'),
        );
      } finally {
        key.close();
      }
      _notify();
      return const ProxyApplyResult(ok: true);
    } catch (e) {
      return ProxyApplyResult(ok: false, error: '设置系统代理失败：$e');
    }
  }

  ProxyApplyResult disable() {
    if (!supported) return const ProxyApplyResult(ok: true);
    return _restore(force: false);
  }

  ProxyApplyResult restoreIfOwned({bool force = false}) {
    if (!supported) return const ProxyApplyResult(ok: true);
    return _restore(force: force);
  }

  ProxyApplyResult _restore({required bool force}) {
    try {
      final ownedFile = File(paths.proxySnapshotFile.path);
      if (!ownedFile.existsSync()) return const ProxyApplyResult(ok: true);
      final snapshot = SystemProxySnapshot.fromJson(
        Map<String, dynamic>.from(jsonDecode(ownedFile.readAsStringSync()) as Map),
      );
      final key = _openSettings();
      try {
        final current = key.getString('ProxyServer');
        final currentEnabled = key.getInt('ProxyEnable');
        final ours = snapshot.appliedServer ?? _server;
        final stillOwned = ours != null && current == ours && currentEnabled == 1;
        if (!force && !stillOwned) {
          // Another program changed or disabled the proxy after us; keep its change.
          ownedFile.deleteSync();
          return const ProxyApplyResult(ok: true);
        }
        _restoreValue(key, 'ProxyEnable', snapshot.proxyEnable, isDword: true);
        _restoreValue(key, 'ProxyServer', snapshot.proxyServer);
        _restoreValue(key, 'ProxyOverride', snapshot.proxyOverride);
        _restoreValue(key, 'AutoConfigURL', snapshot.autoConfigUrl);
      } finally {
        key.close();
      }
      ownedFile.deleteSync();
      _notify();
      return const ProxyApplyResult(ok: true);
    } catch (e) {
      return ProxyApplyResult(ok: false, error: '恢复系统代理失败：$e');
    }
  }

  SystemProxySnapshot _readSnapshot(RegistryKey key) {
    return SystemProxySnapshot(
      proxyEnable: key.getInt('ProxyEnable'),
      proxyServer: key.getString('ProxyServer'),
      proxyOverride: key.getString('ProxyOverride'),
      autoConfigUrl: key.getString('AutoConfigURL'),
    );
  }

  void _restoreValue(RegistryKey key, String name, Object? value, {bool isDword = false}) {
    if (value == null) {
      _removeValue(key, name);
      return;
    }
    if (isDword) {
      key.setValue(name, RegistryValue.dword(value as int));
    } else {
      key.setValue(name, RegistryValue.string(value as String));
    }
  }

  void _removeValue(RegistryKey key, String name) {
    try {
      key.removeValue(name);
    } on WindowsException {
      // Missing values are already in the desired state.
    }
  }

  RegistryKey _openSettings() {
    return CURRENT_USER.open(
      _internetSettings,
      config: const RegistryOpenConfig(access: RegistryAccess.readWrite),
    );
  }

  void _notify() {
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final setOption = wininet.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
          int Function(int, int, Pointer<Void>, int)>('InternetSetOptionW');
      setOption(0, _settingsChanged, nullptr, 0);
      setOption(0, _refresh, nullptr, 0);
    } catch (_) {
      // The registry values are still applied; notification is best effort.
    }
  }
}
