import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'system_proxy.dart';

const _success = ProxyApplyResult(ok: true);

String get _configDirectory {
  final environment = Platform.environment;
  final config = environment['XDG_CONFIG_HOME'];
  return config != null && config.startsWith('/')
      ? config
      : '${environment['HOME']}/.config';
}

class LinuxSystemProxy implements SystemProxy {
  LinuxSystemProxy(this._snapshot, this._settings);

  final File _snapshot;
  final LinuxProxySettings _settings;
  Future<ProxyApplyResult> _pending = Future.value(_success);

  static Future<LinuxSystemProxy?> detect(File snapshot) async {
    final environment = Platform.environment;
    final desktops =
        [environment['XDG_CURRENT_DESKTOP'], environment['XDG_SESSION_DESKTOP']]
            .whereType<String>()
            .expand((value) => value.toLowerCase().split(':'))
            .toSet();
    final bus = environment['DBUS_SESSION_BUS_ADDRESS'];
    if (bus == null || bus.isEmpty) return null;

    final LinuxProxySettings settings;
    if (desktops.contains('kde') || desktops.contains('plasma')) {
      settings = _KdeProxySettings(
        environment['KDE_SESSION_VERSION'] == '6' ? 6 : 5,
      );
    } else if (desktops.contains('gnome') || desktops.contains('ubuntu')) {
      settings = _GnomeProxySettings();
    } else {
      return null;
    }
    try {
      return await settings.available()
          ? LinuxSystemProxy(snapshot, settings)
          : null;
    } on Exception {
      return null;
    }
  }

  Future<ProxyApplyResult> _serialize(Future<void> Function() operation) {
    return _pending = _pending.then((_) async {
      try {
        await operation();
        return _success;
      } on Exception catch (error) {
        return ProxyApplyResult(ok: false, error: '系统代理操作失败：$error');
      }
    });
  }

  @override
  Future<ProxyApplyResult> enable(int port) => _serialize(() async {
    if (port < 1 || port > 65535) throw const FormatException('代理端口无效');
    await _restore();
    final applied = _settings.valuesFor(port);
    final previous = <String, String?>{
      for (final key in applied.keys) key: await _settings.read(key),
    };
    // The same journal covers partial writes and abrupt application exits.
    final temp = File('${_snapshot.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'adapter': _settings.id,
        'previous': previous,
        'applied': applied,
      }),
      flush: true,
    );
    await temp.rename(_snapshot.path);
    try {
      for (final entry in applied.entries) {
        await _settings.write(entry.key, entry.value);
        if (await _settings.read(entry.key) != entry.value) {
          throw const FormatException('桌面未接受代理设置');
        }
      }
      await _settings.reload();
    } on Exception catch (error) {
      try {
        await _restore();
      } on Exception catch (restoreError) {
        throw FormatException('$error；回滚失败，已保留恢复记录：$restoreError');
      }
      rethrow;
    }
  });

  @override
  Future<ProxyApplyResult> disable() => _serialize(_restore);

  @override
  Future<ProxyApplyResult> restoreIfOwned() => disable();

  Future<void> _restore() async {
    if (!await _snapshot.exists()) return;
    final data = jsonDecode(await _snapshot.readAsString());
    if (data is! Map || data['adapter'] != _settings.id) {
      throw const FormatException('请在原桌面会话中恢复上一次的代理设置');
    }
    final previous = data['previous'];
    final applied = data['applied'];
    final keys = _settings.valuesFor(1).keys;
    if (previous is! Map ||
        applied is! Map ||
        !keys.every(
          (key) =>
              previous.containsKey(key) &&
              (previous[key] == null || previous[key] is String) &&
              applied[key] is String,
        )) {
      throw const FormatException('系统代理恢复记录无效');
    }
    // Restore mode last, just as when enabling.
    final failures = <String>[];
    for (final key in keys) {
      try {
        if (previous[key] != applied[key] &&
            await _settings.read(key) == applied[key]) {
          await _settings.write(key, previous[key] as String?);
          if (await _settings.read(key) != previous[key]) {
            throw const FormatException('桌面未恢复代理设置');
          }
        }
      } on Exception {
        failures.add(key);
      }
    }
    await _settings.reload();
    if (failures.isNotEmpty) {
      throw FormatException('有 ${failures.length} 项代理设置尚未恢复');
    }
    await _snapshot.delete();
  }
}

abstract interface class LinuxProxySettings {
  String get id;
  Future<bool> available();
  Map<String, String> valuesFor(int port);
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
  Future<void> reload();
}

Future<String> _command(String executable, List<String> args) async {
  final process = await Process.start('/usr/bin/$executable', args);
  final output = utf8.decoder.bind(process.stdout).join();
  final errors = process.stderr.drain<void>();
  try {
    final code = await process.exitCode.timeout(const Duration(seconds: 3));
    await errors;
    final value = await output;
    if (code != 0) throw FormatException('$executable 退出代码 $code');
    return value.endsWith('\n') ? value.substring(0, value.length - 1) : value;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw FormatException('$executable 执行超时');
  }
}

class _GnomeProxySettings implements LinuxProxySettings {
  @override
  String get id =>
      'gnome:$_configDirectory:${Platform.environment['DCONF_PROFILE'] ?? ''}';

  static const _schema = 'org.gnome.system.proxy';

  static const _channel = MethodChannel('nekoproxy/linux_system_proxy');

  Map<String, String?> _setting(String key, [String? value]) {
    final parts = key.split('/');
    return {
      'schema': parts.length == 2 ? '$_schema.${parts.first}' : _schema,
      'key': parts.last,
      'value': value,
    };
  }

  @override
  Future<bool> available() async {
    if (!const {
      null,
      'dconf',
    }.contains(Platform.environment['GSETTINGS_BACKEND'])) {
      return false;
    }
    for (final key in valuesFor(1).keys) {
      if (await _channel.invokeMethod<bool>('writable', _setting(key)) !=
          true) {
        return false;
      }
    }
    return true;
  }

  @override
  Map<String, String> valuesFor(int port) => {
    for (final protocol in ['http', 'https', 'socks']) ...{
      '$protocol/host': "'127.0.0.1'",
      '$protocol/port': '$port',
    },
    'http/use-authentication': 'false',
    'ignore-hosts': "['localhost', '127.0.0.0/8', '::1']",
    'mode': "'manual'",
  };

  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', _setting(key));

  @override
  Future<void> write(String key, String? value) =>
      _channel.invokeMethod<void>('write', _setting(key, value));

  @override
  Future<void> reload() async {}
}

class _KdeProxySettings implements LinuxProxySettings {
  _KdeProxySettings(this._version);

  final int _version;

  @override
  String get id => 'kde:$_configDirectory';

  List<String> _setting(String key) {
    return [
      '--file',
      '$_configDirectory/kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      key,
    ];
  }

  @override
  Future<bool> available() async {
    if (!File('/usr/bin/kwriteconfig$_version').existsSync() ||
        !File('/usr/bin/dbus-send').existsSync() ||
        Platform.environment['HOME'] == null) {
      return false;
    }
    await read('ProxyType');
    return true;
  }

  @override
  Map<String, String> valuesFor(int port) => {
    'httpProxy': 'http://127.0.0.1:$port',
    'httpsProxy': 'http://127.0.0.1:$port',
    'socksProxy': 'socks://127.0.0.1:$port',
    'NoProxyFor': 'localhost,127.0.0.1,::1',
    'ReversedException': 'false',
    'ProxyType': '1',
  };

  @override
  Future<String?> read(String key) async {
    const missing = 'NekoProxy-missing-4b995f5c';
    final value = await _command('kreadconfig$_version', [
      ..._setting(key),
      '--default',
      missing,
    ]);
    if (key.endsWith('Proxy') && value.contains('@')) {
      // KConfig's command-line writer would expose the previous URL through
      // argv if it contains a username or password.
      throw const FormatException('已有 KDE 代理包含认证信息，请手动配置本地代理');
    }
    return value == missing ? null : value;
  }

  @override
  Future<void> write(String key, String? value) async {
    await _command('kwriteconfig$_version', [
      ..._setting(key),
      if (_version == 6) '--notify',
      if (value == null) '--delete' else ...['--', value],
    ]);
  }

  @override
  Future<void> reload() async {
    await _command('dbus-send', [
      '--session',
      '--type=signal',
      '/KIO/Scheduler',
      'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
      'string:',
    ]);
  }
}
