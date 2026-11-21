import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../data/app_storage.dart';

class RuntimeException implements Exception {
  const RuntimeException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RuntimeGroup {
  const RuntimeGroup({
    required this.kind,
    required this.selected,
    required this.all,
  });
  final String kind;
  final String selected;
  final List<String> all;
}

class RuntimeStatus {
  const RuntimeStatus({
    required this.running,
    this.error,
    this.startedAt,
    this.uptimeMs = 0,
    this.groups = const {},
    this.inboundPort = 0,
  });

  final bool running;
  final String? error;
  final int? startedAt;
  final int uptimeMs;
  final Map<String, RuntimeGroup> groups;
  final int inboundPort;

  RuntimeGroup? get manualGroup => groups['proxy'];
  RuntimeGroup? get autoGroup => groups['auto'];
}

class RuntimeTraffic {
  const RuntimeTraffic({
    this.uploaded = 0,
    this.downloaded = 0,
    this.connections = 0,
    this.uptimeMs = 0,
  });
  final int uploaded;
  final int downloaded;
  final int connections;
  final int uptimeMs;

  Map<String, dynamic> toJson() => {
    'uploaded': uploaded,
    'downloaded': downloaded,
    'connections': connections,
    'uptimeMs': uptimeMs,
  };

  factory RuntimeTraffic.fromJson(Map<String, dynamic> json) => RuntimeTraffic(
    uploaded: (json['uploaded'] as num?)?.toInt() ?? 0,
    downloaded: (json['downloaded'] as num?)?.toInt() ?? 0,
    connections: (json['connections'] as num?)?.toInt() ?? 0,
    uptimeMs: (json['uptimeMs'] as num?)?.toInt() ?? 0,
  );
}

class RuntimeConnection {
  const RuntimeConnection({
    required this.id,
    required this.network,
    required this.source,
    required this.destination,
    required this.domain,
    required this.outbound,
    required this.rule,
    this.ruleIndex,
    required this.uploaded,
    required this.downloaded,
    required this.createdAt,
  });

  final String id;
  final String network;
  final String source;
  final String destination;
  final String domain;
  final String outbound;
  final String rule;
  final int? ruleIndex;
  final int uploaded;
  final int downloaded;
  final int createdAt;

  factory RuntimeConnection.fromJson(Map<String, dynamic> json) =>
      RuntimeConnection(
        id: json['id'] as String? ?? '',
        network: json['network'] as String? ?? '',
        source: json['source'] as String? ?? '',
        destination: json['destination'] as String? ?? '',
        domain: json['domain'] as String? ?? '',
        outbound: json['outbound'] as String? ?? '',
        rule: json['rule'] as String? ?? '',
        ruleIndex: json['ruleIndex'] as int?,
        uploaded: (json['uploaded'] as num?)?.toInt() ?? 0,
        downloaded: (json['downloaded'] as num?)?.toInt() ?? 0,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );
}

class RuntimeTestResult {
  const RuntimeTestResult({this.delay, this.error});
  final int? delay;
  final String? error;
}

class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.label,
    this.system = false,
  });

  final String packageName;
  final String label;
  final bool system;

  factory InstalledApp.fromJson(Map<String, dynamic> json) => InstalledApp(
    packageName: json['package'] as String? ?? '',
    label: json['label'] as String? ?? '',
    system: json['system'] == true,
  );
}

abstract class RuntimeClient {
  Future<RuntimeStatus> start({
    required String config,
    required String mode,
    String perAppMode = 'off',
    List<String> perAppPackages = const [],
  });
  Future<RuntimeStatus> fetchStatus();
  Future<RuntimeTraffic> fetchTraffic();
  Future<List<RuntimeConnection>> fetchConnections();
  Future<void> select(String tag);

  /// Applies one completed round; a null delay marks a failed probe.
  Future<void> refreshAuto(Map<String, int?> delays);
  Future<Map<String, RuntimeTestResult>> test(List<String> tags, String url);
  Future<void> startTest({required String config});
  Future<void> stopTest();
  Future<void> closeConnection(String id);
  Future<void> clearConnections();
  Future<void> shutdown();
  Future<void> cleanupStale();
  Future<List<InstalledApp>> installedApps() async => const [];
  Future<Uint8List?> installedAppIcon(String packageName, int size) async =>
      null;
  Future<List<String>> systemDnsServers() async => const [];
}

class DesktopRuntimeClient implements RuntimeClient {
  DesktopRuntimeClient(this.paths);

  final AppPaths paths;
  Process? _process;
  Socket? _socket;
  StreamSubscription<String>? _lineSubscription;
  Timer? _heartbeat;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  Completer<void>? _authorization;
  int _nextId = 1;
  String? _token;
  bool _authorized = false;
  bool _stopping = false;
  String? _lastError;
  int? _exitCode;
  bool _linuxConnected = false;

  File get _readyFile =>
      File('${paths.runtime.path}${Platform.pathSeparator}ready.json');
  File get _errorFile => File('${_readyFile.path}.error');

  @override
  Future<List<InstalledApp>> installedApps() async => const [];

  @override
  Future<Uint8List?> installedAppIcon(String packageName, int size) async =>
      null;

  @override
  Future<List<String>> systemDnsServers() async => const [];

  @override
  Future<RuntimeStatus> start({
    required String config,
    required String mode,
    String perAppMode = 'off',
    List<String> perAppPackages = const [],
  }) async {
    await shutdown();
    _stopping = false;
    _lastError = null;
    _exitCode = null;
    await paths.runtime.create(recursive: true);
    if (await _readyFile.exists()) await _readyFile.delete();
    if (await _errorFile.exists()) await _errorFile.delete();
    if (await paths.logFile.exists()) await paths.logFile.delete();

    final token = Platform.isLinux ? null : _randomToken();
    final worker = desktopWorkerPath(tun: mode == 'tun');

    final process = await _startWorker(
      worker,
      [
        if (Platform.isLinux && mode == 'tun') '-supervise-tun',
        '-config',
        '-',
        '-ready',
        _readyFile.path,
        '-log',
        paths.logFile.path,
        '-install-dir',
        Platform.isLinux ? paths.base.path : paths.base.parent.path,
        if (token != null) ...['-token', token],
        '-mode',
        mode,
        '-lease',
        '120',
      ],
      workingDirectory: paths.runtime.path,
      environment: {'TEMP': paths.runtime.path, 'TMP': paths.runtime.path},
      runInShell: false,
    );
    _process = process;
    if (Platform.isLinux) {
      // Even a startup error before the log is opened must drain the pipes.
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
    }
    process.stdin.add(utf8.encode(config));
    await process.stdin.close();
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _exitCode = code;
          if (!_stopping) _lastError = '内核进程已退出（代码 $code）';
        }
      }),
    );

    final ready = await _waitForReady(process);
    _token = ready['token'] as String? ?? token;
    if (_token == null) throw const RuntimeException('内核未提供控制令牌。');
    await _connect(ready['port'] as int);
    final status = await fetchStatus();
    if (Platform.isLinux) {
      if (!status.running) throw RuntimeException(status.error ?? '内核已停止');
      _linuxConnected = true;
    }
    return status;
  }

  Future<String?> _readWorkerError() async {
    try {
      final message = (await _errorFile.readAsString()).trim();
      return message.isEmpty ? null : message;
    } on FileSystemException {
      // The worker creates this file only when it has an error to report.
      return null;
    }
  }

  Future<Process> _startWorker(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
  }) async {
    try {
      return await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: runInShell,
      );
    } on ProcessException catch (error) {
      if (Platform.isLinux && executable == linuxTunWorkerPath) {
        throw const RuntimeException('无法启动 TUN 组件。请确认当前用户已获得 TUN 授权并重新登录。');
      }
      throw RuntimeException('无法启动内核（错误代码 ${error.errorCode}）');
    }
  }

  Future<Map<String, dynamic>> _waitForReady(Process process) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (!identical(_process, process) || _stopping) {
        throw const RuntimeException('内核启动已取消');
      }
      if (await _readyFile.exists()) {
        try {
          final data = jsonDecode(await _readyFile.readAsString());
          if (data is Map && data['port'] is num) {
            return Map<String, dynamic>.from(data);
          }
        } catch (_) {}
      }
      if (await _errorFile.exists()) {
        final message = await _errorFile.readAsString();
        throw RuntimeException(
          message.trim().isEmpty ? '内核启动失败' : message.trim(),
        );
      }
      if (_process != null) {
        final exit = await _process!.exitCode.timeout(
          const Duration(milliseconds: 1),
          onTimeout: () => -999,
        );
        if (exit != -999) {
          throw RuntimeException(_lastError ?? '内核进程已退出');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const RuntimeException('等待内核启动超时');
  }

  Future<void> _connect(int port) async {
    await _closeSocket();
    final socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(seconds: 8),
    );
    _socket = socket;
    _authorized = false;
    _authorization = Completer<void>();
    _lineSubscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (Object error) {
            _lastError = '控制连接错误：$error';
            _failPending(error.toString());
          },
          onDone: () {
            _failPending('控制连接已关闭');
            _authorized = false;
          },
        );
    socket.write('${jsonEncode({'token': _token})}\n');
    await _authorization!.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        throw const RuntimeException('控制通道鉴权超时');
      },
    );
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_socket == null) return;
      unawaited(
        _request(
          'ping',
          const {},
          timeout: const Duration(seconds: 5),
        ).then((_) {}, onError: (_) {}),
      );
    });
  }

  void _handleLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final map = Map<String, dynamic>.from(decoded);
    final id = (map['id'] as num?)?.toInt() ?? 0;
    if (id == 0) {
      if (map['ok'] == true) {
        _authorized = true;
        if (!(_authorization?.isCompleted ?? true)) _authorization?.complete();
      } else {
        if (!(_authorization?.isCompleted ?? true)) {
          _authorization?.completeError(const RuntimeException('控制通道鉴权失败'));
        }
      }
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (map['ok'] == true) {
      completer.complete(map);
    } else {
      completer.completeError(
        RuntimeException(map['error'] as String? ?? '内核返回错误'),
      );
    }
  }

  Future<Map<String, dynamic>> _request(
    String command,
    Map<String, Object?> arguments, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final socket = _socket;
    if (socket == null || !_authorized) throw const RuntimeException('内核尚未连接');
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    socket.write('${jsonEncode({'id': id, 'cmd': command, ...arguments})}\n');
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      throw RuntimeException('内核响应超时');
    }
  }

  void _failPending(String message) {
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted)
        completer.completeError(RuntimeException(message));
    }
  }

  @override
  Future<RuntimeStatus> fetchStatus() async {
    if (Platform.isLinux && _exitCode != null) {
      _linuxConnected = false;
      return RuntimeStatus(
        running: false,
        error: await _readWorkerError() ?? _lastError,
      );
    }
    final response = await _request('status', const {});
    final data = Map<String, dynamic>.from(
      response['data'] as Map? ?? const {},
    );
    final groups = <String, RuntimeGroup>{};
    final rawGroups = data['groups'];
    if (rawGroups is Map) {
      for (final entry in rawGroups.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        groups[entry.key.toString()] = RuntimeGroup(
          kind: value['kind'] as String? ?? '',
          selected: value['selected'] as String? ?? '',
          all: (value['all'] as List? ?? const [])
              .map((e) => e.toString())
              .toList(),
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

  @override
  Future<RuntimeTraffic> fetchTraffic() async {
    final response = await _request('traffic', const {});
    return RuntimeTraffic.fromJson(
      Map<String, dynamic>.from(response['data'] as Map? ?? const {}),
    );
  }

  @override
  Future<List<RuntimeConnection>> fetchConnections() async {
    final response = await _request('connections', const {});
    final list = response['data'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => RuntimeConnection.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  @override
  Future<void> select(String tag) async {
    await _request('select', {'tag': tag});
  }

  @override
  Future<void> refreshAuto(Map<String, int?> delays) async {
    await _request('refresh-auto', {'delays': delays});
  }

  @override
  Future<Map<String, RuntimeTestResult>> test(
    List<String> tags,
    String url,
  ) async {
    final response = await _request('test', {
      'tags': tags,
      'url': url,
    }, timeout: const Duration(seconds: 45));
    final data = response['data'];
    final result = <String, RuntimeTestResult>{};
    if (data is Map) {
      for (final entry in data.entries) {
        final value = entry.value;
        if (value is Map && value['delay'] is num) {
          result[entry.key.toString()] = RuntimeTestResult(
            delay: (value['delay'] as num).toInt(),
          );
        } else if (value is Map) {
          result[entry.key.toString()] = RuntimeTestResult(
            error: value['error']?.toString() ?? '测速失败',
          );
        }
      }
    }
    return result;
  }

  @override
  Future<void> startTest({required String config}) async {
    await start(config: config, mode: 'test');
  }

  @override
  Future<void> stopTest() => shutdown();

  @override
  Future<void> closeConnection(String id) async {
    await _request('closeConnection', {'connectionId': id});
  }

  @override
  Future<void> clearConnections() async {
    await _request('clear', const {});
  }

  @override
  Future<void> shutdown() async {
    _stopping = true;
    final reportError = _linuxConnected;
    _linuxConnected = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    final socket = _socket;
    if (socket != null && _authorized) {
      try {
        await _request(
          'shutdown',
          const {},
          timeout: const Duration(seconds: 4),
        );
      } catch (_) {}
    }
    await _closeSocket();
    final process = _process;
    int? exitCode;
    if (process != null) {
      try {
        exitCode = await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill();
        try {
          exitCode = await process.exitCode.timeout(
            Duration(seconds: Platform.isLinux ? 8 : 2),
          );
        } catch (_) {}
      }
    }
    _process = null;
    _authorized = false;
    _stopping = false;
    if (reportError && exitCode != 0) {
      final message = await _readWorkerError();
      throw RuntimeException(message ?? 'Linux 内核关闭失败');
    }
  }

  @override
  Future<void> cleanupStale() async {
    if (!await _readyFile.exists()) return;
    try {
      final decoded = jsonDecode(await _readyFile.readAsString());
      if (decoded is! Map) return;
      final port = (decoded['port'] as num?)?.toInt();
      final token = decoded['token'] as String?;
      if (port == null || token == null) return;
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(seconds: 1),
      );
      _socket = socket;
      _token = token;
      _authorized = false;
      _authorization = Completer<void>();
      _lineSubscription = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLine);
      socket.write('${jsonEncode({'token': token})}\n');
      await _authorization!.future.timeout(const Duration(seconds: 2));
      await _request('shutdown', const {}, timeout: const Duration(seconds: 2));
    } catch (_) {
      // A stale worker may already be gone or be owned by a different session.
    } finally {
      await _closeSocket();
      try {
        if (await _readyFile.exists()) await _readyFile.delete();
      } catch (_) {}
      _authorized = false;
    }
  }

  Future<void> _closeSocket() async {
    await _lineSubscription?.cancel();
    _lineSubscription = null;
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    _failPending('控制连接已关闭');
  }

  String _randomToken() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

const linuxTunWorkerPath = '/usr/lib/nekoproxy/nekoproxy-tun-worker';

String desktopWorkerPath({bool tun = false}) {
  if (Platform.isLinux && tun) {
    if (!File(linuxTunWorkerPath).existsSync()) {
      throw const RuntimeException('缺少 TUN 组件，请安装 NekoProxy 的 .deb 软件包。');
    }
    return linuxTunWorkerPath;
  }
  final name = Platform.isLinux ? 'nekoproxy-worker' : 'nekoproxy-worker.exe';
  return locateRuntimeBinary(name) ??
      (throw RuntimeException('未找到 $name，请先构建运行组件。'));
}

String? locateRuntimeBinary(String name) {
  final candidates = <String>[];
  final env = Platform.environment['NEKOPROXY_RUNTIME_DIR'];
  if (env != null && env.isNotEmpty) {
    candidates.add('$env${Platform.pathSeparator}$name');
  }
  final exeDir = File(Platform.resolvedExecutable).parent;
  candidates.add('${exeDir.path}${Platform.pathSeparator}$name');
  candidates.add(
    '${exeDir.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}$name',
  );
  var directory = exeDir;
  for (var i = 0; i < 5; i++) {
    candidates.add(
      '${directory.path}${Platform.pathSeparator}build${Platform.pathSeparator}$name',
    );
    directory = directory.parent;
  }
  candidates.add(
    '${Directory.current.path}${Platform.pathSeparator}build${Platform.pathSeparator}$name',
  );
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
