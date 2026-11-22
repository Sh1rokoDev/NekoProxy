import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/config_compiler.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/runtime/runtime_client.dart';
import 'package:nekoproxy/services/rule_set_manager.dart';
import 'package:nekoproxy/services/system_proxy.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('启动失败可重试，同一时刻只初始化一次', () async {
    final directory = await Directory.systemTemp.createTemp('neko-start-');
    addTearDown(() => directory.delete(recursive: true));
    final paths = _FailingPaths(AppPaths.forDirectory(directory.path));
    final controller = AppController();
    addTearDown(controller.dispose);

    final first = controller.initialize(appPaths: paths);
    expect(controller.initialize(appPaths: paths), same(first));
    await expectLater(first, throwsA(isA<FileSystemException>()));
    expect(controller.initialized, isFalse);
    expect(controller.appearanceTick.value, 0);

    paths.fail = false;
    await controller.initialize(appPaths: paths);
    expect(controller.initialized, isTrue);
    expect(controller.paths, same(paths));
    expect(controller.appearanceTick.value, 1);
    await controller.initialize(appPaths: paths);
    expect(controller.appearanceTick.value, 1);
  });

  test('启动结果尚未就绪时退出，不访问未赋值的核心', () async {
    final directory = await Directory.systemTemp.createTemp('neko-exit-');
    addTearDown(directory.delete);
    final paths = AppPaths.forDirectory(directory.path);
    final controller = AppController();
    addTearDown(controller.dispose);

    final startup = controller.initialize(appPaths: paths);
    await controller.shutdownForExit();
    await startup;
    expect(controller.initialized, isFalse);
    expect(controller.appearanceTick.value, 0);
  });

  test('恢复与重置仅在保存成功后更新主题和强调色', () async {
    final storage = _MemoryStorage();
    final controller = _AppearanceController()..storage = storage;
    addTearDown(controller.dispose);
    controller.settings.theme = ThemePreference.light;
    final restored = AppSnapshot.empty();
    restored.settings
      ..theme = ThemePreference.dark
      ..seedColor = 0xFF222299;
    final backup = jsonEncode({
      'app': 'nekoproxy',
      'version': 2,
      'data': restored.toJson(),
    });
    final observed = <(ThemePreference, int)>[];
    controller.appearanceTick.addListener(() {
      observed.add((controller.settings.theme, controller.settings.seedColor));
    });

    storage.fail = true;
    await expectLater(controller.importBackup(backup), throwsStateError);
    expect(observed, isEmpty);
    expect(controller.settings.theme, ThemePreference.light);

    storage.fail = false;
    await controller.importBackup(backup);
    await controller.resetAll();
    expect(observed, [
      (ThemePreference.dark, restored.settings.seedColor),
      (ThemePreference.system, AppSettings().seedColor),
    ]);
  });

  for (final rejectConfig in [false, true]) {
    test(
      rejectConfig ? '高级配置写盘失败后仍可保存并发的外观设置' : '并发保存外观设置时保留已提交的高级配置',
      () async {
        final original = _mixedConfig(18080);
        final candidate = _mixedConfig(18081);
        final release = Completer<void>();
        final storage = _MemoryStorage()
          ..holdWrites = release.future
          ..rejectedConfig = rejectConfig ? candidate : null;
        final controller = AppController()..storage = storage;
        addTearDown(controller.dispose);
        controller.snapshot
          ..useCustomConfig = true
          ..customConfig = original;

        final application = controller.saveAdvancedConfig(
          AdvancedConfigMode.override,
          candidate,
        );
        final outcome = rejectConfig
            ? expectLater(application, throwsStateError)
            : application;
        await storage.writeStarted.future;
        controller.settings.theme = ThemePreference.dark;
        final settings = controller.saveSettings();
        release.complete();
        await Future.wait([outcome, settings]);

        final expected = rejectConfig ? original : candidate;
        expect(controller.snapshot.customConfig, expected);
        expect(storage.savedConfig, expected);
        expect(storage.savedTheme, ThemePreference.dark);
      },
    );
  }

  test('高级配置在核心和代理就绪后提交，失败时恢复原端口', () async {
    final storage = _MemoryStorage();
    final core = _FakeCore();
    final proxy = _FakeProxy();
    final controller = _ConfigApplyController()
      ..paths = storage.paths
      ..storage = storage
      ..runtime = core
      ..ruleSets = RuleSetManager(
        paths: storage.paths,
        clientFactory: HttpClient.new,
      )
      ..systemProxy = proxy;
    addTearDown(controller.dispose);
    controller.snapshot
      ..useCustomConfig = true
      ..customConfig = _mixedConfig(18080);
    controller.settings.inbound = InboundSettings(localPort: 7890);
    controller.settings.systemProxyEnabled = true;
    await controller.connect();
    expect(proxy.port, 18080);

    Future<void> apply(int port, {String? username}) =>
        controller.saveAdvancedConfig(
          AdvancedConfigMode.override,
          _mixedConfig(port, username: username),
        );
    void expectOldConnection() {
      expect(core.port, 18080);
      expect(proxy.port, 18080);
      expect(storage.savedConfig, _mixedConfig(18080));
      expect(controller.snapshot.customConfig, _mixedConfig(18080));
      expect(controller.running, isTrue);
    }

    core.invalidPort = 18081;
    await expectLater(apply(18081), throwsA(isA<RuntimeException>()));
    expect(core.starts, [18080]);
    expectOldConnection();

    core.invalidPort = null;
    await expectLater(apply(18081, username: 'fixture'), throwsException);
    final absent = jsonDecode(_mixedConfig(18081)) as Map<String, dynamic>;
    final duplicate = jsonDecode(_mixedConfig(18081)) as Map<String, dynamic>;
    final inbounds = duplicate['inbounds'] as List<dynamic>;
    inbounds.add({
      ...inbounds.first as Map,
      'tag': 'other',
      'listen_port': 18086,
    });
    absent['inbounds'] = [];
    for (final config in [absent, duplicate]) {
      await expectLater(
        controller.saveAdvancedConfig(
          AdvancedConfigMode.override,
          jsonEncode(config),
        ),
        throwsA(isA<ConfigCompileException>()),
      );
    }
    expect(core.starts, [18080]);
    expectOldConnection();

    core.conflictPorts.add(18082);
    await expectLater(apply(18082), throwsException);
    expect(core.starts, [18080, 18082, 18080]);
    expectOldConnection();

    proxy.failPort = 18083;
    await expectLater(apply(18083), throwsException);
    expectOldConnection();

    storage.rejectedConfig = _mixedConfig(18084);
    await expectLater(apply(18084), throwsException);
    expectOldConnection();

    await apply(18085);
    expect(core.port, 18085);
    expect(proxy.port, 18085);
    expect(storage.savedConfig, _mixedConfig(18085));
    expect(controller.snapshot.customConfig, _mixedConfig(18085));

    core.conflictPorts.addAll([18085, 18086]);
    await expectLater(
      apply(18086),
      throwsA(
        isA<ConfigCompileException>().having(
          (error) => error.message,
          '恢复结果',
          contains('原连接恢复失败'),
        ),
      ),
    );
    expect(storage.savedConfig, _mixedConfig(18085));
    expect(controller.snapshot.customConfig, _mixedConfig(18085));
    expect(controller.running, isFalse);
    expect(proxy.port, isNull);
  });
}

String _mixedConfig(int port, {String? username}) => jsonEncode({
  'inbounds': [
    {
      'type': 'mixed',
      'tag': 'local',
      'listen': '127.0.0.1',
      'listen_port': port,
      if (username != null)
        'users': [
          {'username': username, 'password': 'fixture'},
        ],
    },
  ],
  'outbounds': [
    {'type': 'direct', 'tag': 'direct'},
  ],
});

class _ConfigApplyController extends AppController {
  @override
  Future<void> refreshExitInfo() async {}
}

class _FakeCore extends Fake implements RuntimeConfigValidator {
  int? port;
  int? invalidPort;
  final conflictPorts = <int>{};
  final starts = <int>[];

  int _portOf(String config) =>
      (jsonDecode(config) as Map)['inbounds'][0]['listen_port'] as int;

  @override
  Future<void> validateConfig(String config) async {
    if (invalidPort != null && _portOf(config) == invalidPort) {
      throw const RuntimeException('预检失败');
    }
  }

  @override
  Future<List<String>> systemDnsServers() async => [];

  @override
  Future<RuntimeStatus> fetchStatus() async =>
      RuntimeStatus(running: port != null, inboundPort: port ?? 0);

  @override
  Future<RuntimeStatus> start({
    required String config,
    required String mode,
    String perAppMode = 'off',
    List<String> perAppPackages = const [],
  }) async {
    final next = _portOf(config);
    starts.add(next);
    if (conflictPorts.contains(next)) throw const RuntimeException('端口已占用');
    port = next;
    return fetchStatus();
  }

  @override
  Future<void> shutdown() async {
    port = null;
  }
}

class _FakeProxy implements SystemProxy {
  int? port;
  int? failPort;

  @override
  ProxyApplyResult enable(int port) {
    if (port == failPort) {
      return const ProxyApplyResult(ok: false, error: '设置代理失败');
    }
    this.port = port;
    return const ProxyApplyResult(ok: true);
  }

  @override
  ProxyApplyResult disable() {
    port = null;
    return const ProxyApplyResult(ok: true);
  }

  @override
  ProxyApplyResult restoreIfOwned() => disable();
}

class _FailingPaths extends AppPaths {
  _FailingPaths(AppPaths paths)
    : super(base: paths.base, runtime: paths.runtime, logFile: paths.logFile);

  bool fail = true;

  @override
  File get proxySnapshotFile {
    if (fail) throw const FileSystemException('模拟初始化中断');
    return super.proxySnapshotFile;
  }
}

class _AppearanceController extends AppController {
  @override
  Future<void> disconnect({bool silent = false}) async {}
}

class _MemoryStorage extends AppStorage {
  _MemoryStorage() : super(AppPaths.forDirectory('.'));

  bool fail = false;
  String? rejectedConfig;
  String? savedConfig;
  ThemePreference? savedTheme;
  final writeStarted = Completer<void>();
  Future<void>? holdWrites;

  @override
  Future<void> save(AppSnapshot snapshot) async {
    final config = snapshot.customConfig;
    final theme = snapshot.settings.theme;
    if (!writeStarted.isCompleted) writeStarted.complete();
    await holdWrites;
    if (fail || config == rejectedConfig) {
      throw StateError('模拟保存失败');
    }
    savedConfig = config;
    savedTheme = theme;
  }
}
