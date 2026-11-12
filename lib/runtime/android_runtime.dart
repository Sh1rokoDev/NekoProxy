import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../data/app_storage.dart';
import 'runtime_client.dart';

/// Bridges to the Android VpnService host. The Kotlin side owns the VPN
/// lifecycle and passes the TUN descriptor to the same Go sing-box engine.
class AndroidRuntimeClient implements RuntimeClient {
  AndroidRuntimeClient(this.paths);

  static const _channel = MethodChannel('nekoproxy/runtime');
  static const _callTimeout = Duration(seconds: 8);
  static const _stopTimeout = Duration(seconds: 4);
  final AppPaths paths;

  Future<T?> _invoke<T>(String method, [Object? arguments]) {
    return _channel.invokeMethod<T>(method, arguments).timeout(_callTimeout);
  }

  @override
  Future<RuntimeStatus> start({
    required String config,
    required String mode,
    String perAppMode = 'off',
    List<String> perAppPackages = const [],
  }) async {
    await shutdown();
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('start', {
      'config': config,
      'cachePath': paths.runtime.path,
      'logPath': paths.logFile.path,
      'perAppMode': perAppMode,
      'perAppPackages': perAppPackages,
    }).timeout(const Duration(seconds: 65));
    return _statusFrom(result);
  }

  @override
  Future<List<InstalledApp>> installedApps() async {
    final result = await _invoke<List<Object?>>('apps');
    return (result ?? const [])
        .whereType<Map>()
        .map((e) => InstalledApp.fromJson(Map<String, dynamic>.from(e)))
        .where((app) => app.packageName.isNotEmpty)
        .toList();
  }

  @override
  Future<List<String>> systemDnsServers() async {
    try {
      final result = await _invoke<List<Object?>>('systemDns');
      return (result ?? const [])
          .whereType<String>()
          .where((value) => value.isNotEmpty)
          .toList();
    } on TimeoutException {
      return const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<RuntimeStatus> fetchStatus() async {
    final result = await _invoke<Map<Object?, Object?>>('status');
    return _statusFrom(result);
  }

  @override
  Future<RuntimeTraffic> fetchTraffic() async {
    final result = await _invoke<Map<Object?, Object?>>('traffic');
    return RuntimeTraffic.fromJson(Map<String, dynamic>.from(result ?? const {}));
  }

  @override
  Future<List<RuntimeConnection>> fetchConnections() async {
    final result = await _invoke<List<Object?>>('connections');
    return (result ?? const [])
        .whereType<Map>()
        .map((e) => RuntimeConnection.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  @override
  Future<void> select(String tag) async {
    await _invoke<void>('select', {'tag': tag});
  }

  @override
  Future<void> refreshAuto(Map<String, int?> delays) async {
    await _invoke<void>('refreshAuto', jsonEncode(delays));
  }

  @override
  Future<Map<String, RuntimeTestResult>> test(List<String> tags, String url) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('test', {
      'tags': tags,
      'url': url,
    }).timeout(const Duration(seconds: 120));
    final output = <String, RuntimeTestResult>{};
    if (result != null) {
      for (final entry in result.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final map = Map<String, dynamic>.from(value);
        output[entry.key.toString()] = RuntimeTestResult(
          delay: (map['delay'] as num?)?.toInt(),
          error: map['error']?.toString(),
        );
      }
    }
    return output;
  }

  @override
  Future<void> startTest({required String config}) async {
    await _channel.invokeMethod<void>('startTest', {
      'config': config,
    }).timeout(const Duration(seconds: 30));
  }

  @override
  Future<void> stopTest() async {
    try {
      await _channel.invokeMethod<void>('stopTest').timeout(const Duration(seconds: 8));
    } on TimeoutException {
      // The Go engine may be draining; never block the next VPN start.
    } on MissingPluginException {
      // Running outside the Android host.
    } on PlatformException {
      // No test engine is active.
    }
  }

  @override
  Future<void> clearConnections() async {
    await _invoke<void>('clear');
  }

  @override
  Future<void> shutdown() async {
    try {
      await _channel.invokeMethod<void>('stop').timeout(_stopTimeout);
    } on TimeoutException {
      // The host is shutting down the engine; do not block reconnection.
    } on MissingPluginException {
      // Running outside the Android host (for example a desktop test).
    } on PlatformException {
      // The service may already be stopped.
    }
  }

  @override
  Future<void> cleanupStale() async {
    try {
      await _invoke<void>('cleanup');
    } on MissingPluginException {
      // No host available.
    }
  }

  RuntimeStatus _statusFrom(Map<Object?, Object?>? raw) {
    final data = Map<String, dynamic>.from(raw ?? const {});
    final groups = <String, RuntimeGroup>{};
    final rawGroups = data['groups'];
    if (rawGroups is Map) {
      for (final entry in rawGroups.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        groups[entry.key.toString()] = RuntimeGroup(
          kind: value['kind'] as String? ?? '',
          selected: value['selected'] as String? ?? '',
          all: (value['all'] as List? ?? const []).map((e) => e.toString()).toList(),
        );
      }
    }
    return RuntimeStatus(
      running: data['running'] == true,
      error: data['error'] as String?,
      startedAt: (data['startedAt'] as num?)?.toInt(),
      uptimeMs: (data['uptimeMs'] as num?)?.toInt() ?? 0,
      groups: groups,
      inboundPort: (data['inboundPort'] as num?)?.toInt() ?? 0,
    );
  }
}

Map<String, dynamic> decodeRuntimeData(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is String) {
    final decoded = jsonDecode(value);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  }
  return {};
}
