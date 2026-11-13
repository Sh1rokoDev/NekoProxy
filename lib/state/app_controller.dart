import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../data/app_storage.dart';
import '../domain/config_compiler.dart';
import '../domain/config_policy.dart';
import '../domain/models.dart';
import '../domain/profile_parser.dart';
import '../runtime/android_runtime.dart';
import '../runtime/runtime_client.dart';
import '../services/app_update_service.dart';
import '../services/backup_service.dart';
import '../services/connectivity_service.dart';
import '../services/exit_info_service.dart';
import '../services/rule_set_manager.dart';
import '../services/windows_system_proxy.dart';

const _latencyTestConcurrency = 32;

class TrafficSample {
  const TrafficSample(this.time, this.up, this.down);
  final DateTime time;
  final double up;
  final double down;
}

class HomeActivity {
  HomeActivity(this.message, {this.failed = false}) : time = DateTime.now();
  final String message;
  final bool failed;
  final DateTime time;
}

class AppController extends ChangeNotifier {
  AppController();

  late final AppPaths paths;
  late final AppStorage storage;
  late final RuntimeClient runtime;
  late final RuleSetManager ruleSets;
  WindowsSystemProxy? systemProxy;

  RuleSetStatus? ruleSetStatus;
  bool updatingRuleSets = false;
  String? ruleSetError;

  final ValueNotifier<int> liveTick = ValueNotifier<int>(0);
  final ValueNotifier<int> appearanceTick = ValueNotifier<int>(0);
  final _connections = ValueNotifier<List<RuntimeConnection>>(const []);

  AppSnapshot snapshot = AppSnapshot.empty();
  bool initialized = false;
  bool busy = false;
  bool running = false;
  bool _changingSplitMode = false;
  bool get canChangeSplitMode => !busy && !_changingSplitMode && !_disposed;
  String? _error;
  String? _notice;
  int _errorRevision = 0;
  int _noticeRevision = 0;

  String? get error => _error;
  int get errorRevision => _errorRevision;
  set error(String? value) {
    _error = value;
    _errorRevision++;
  }

  String? get notice => _notice;
  int get noticeRevision => _noticeRevision;
  set notice(String? value) {
    _notice = value;
    _noticeRevision++;
  }

  String? loadWarning;
  RuntimeStatus? runtimeStatus;
  RuntimeTraffic traffic = const RuntimeTraffic();
  List<RuntimeConnection> get connections => _connections.value;
  set connections(List<RuntimeConnection> value) {
    _connections.value = value.isEmpty ? const [] : value;
  }

  ValueListenable<List<RuntimeConnection>> get connectionUpdates =>
      _connections;

  final _latencies = <String, int>{};
  late final _latencyView = UnmodifiableMapView(_latencies);
  Map<String, int> get latencies => _latencyView;
  set latencies(Map<String, int> values) {
    final copy = Map.of(values);
    _latencies
      ..clear()
      ..addAll(copy);
  }

  final _latencyErrors = <String, String>{};
  late final _latencyErrorView = UnmodifiableMapView(_latencyErrors);
  Map<String, String> get latencyErrors => _latencyErrorView;
  set latencyErrors(Map<String, String> values) {
    final copy = Map.of(values);
    _latencyErrors
      ..clear()
      ..addAll(copy);
  }

  // Replacing a node's configuration also invalidates its offline result.
  final Map<ProxyNode, int> _offlineTestDelays = {};
  String? _offlineTestUrl;
  bool testingNodes = false;
  int testCompleted = 0;
  int testTotal = 0;
  int _testGeneration = 0;
  final _nodeTestRequests = <String?, Set<String>>{};
  bool _drainingNodeTests = false;
  final Map<String, ServiceCheckResult> serviceChecks = {};
  final Set<String> _servicesChecking = {};
  final Set<HttpClient> _serviceAddressClients = {};
  final Map<String, Object> _subscriptionUpdates = {};
  List<TrafficSample> samples = const [];
  DateTime? connectedAt;
  ExitInfo? exitInfo;
  String? exitInfoError;
  bool checkingExitInfo = false;
  HttpClient? _exitInfoClient;
  int _exitInfoGeneration = 0;
  ({String tag, int generation, Object token})? _connectionProbe;
  bool _disposed = false;
  final List<HomeActivity> homeActivities = [];
  CompiledConfig? _compiled;
  Map<String, String> _connectionNodeNames = const {};
  Map<String, String> _nodeIdsByTag = const {};
  String? _effectiveTag;
  bool _unexpectedStop = false;
  bool _temporaryTestRuntime = false;
  List<String> _systemDns = const [];

  Timer? _pollTimer;
  Timer? _uiTimer;
  Timer? _connectionsTimer;
  int _connectionViewers = 0;
  Future<void>? _connectionRefresh;
  Object? _connectionRefreshToken;
  final _closingConnectionIds = <String>{};
  Timer? _subscriptionTimer;
  Timer? _ruleSetTimer;
  Timer? _ruleSetStartupTimer;
  bool _ruleSetUpdatesStopped = false;
  int _pollTicks = 0;
  bool _polling = false;
  int _pollGeneration = 0;
  int _statusRequest = 0;
  int _appliedStatusRequest = 0;
  int _pollFailures = 0;
  bool _rebuilding = false;
  int _lastUpTotal = 0;
  int _lastDownTotal = 0;
  DateTime? _lastTrafficAt;

  bool get isWindows => Platform.isWindows;
  bool get isAndroid => Platform.isAndroid;
  bool get supportsSystemProxy => Platform.isWindows;
  bool get supportsTun => Platform.isWindows || Platform.isAndroid;
  bool get hasNodes => snapshot.hasNodes;

  AppSettings get settings => snapshot.settings;

  void _recordHomeActivity(String message, {bool failed = false}) {
    homeActivities.insert(0, HomeActivity(message, failed: failed));
    if (homeActivities.length > 5) homeActivities.removeLast();
  }

  void _cancelExitInfo() {
    _exitInfoGeneration++;
    _exitInfoClient?.close(force: true);
    _exitInfoClient = null;
    checkingExitInfo = false;
    exitInfo = null;
    exitInfoError = null;
  }

  Future<void> refreshExitInfo() async {
    if (!running || busy || _disposed) return;
    _cancelExitInfo();
    final generation = _exitInfoGeneration;
    final client = _exitInfoClient = _createManagedHttpClient();
    checkingExitInfo = true;
    notifyListeners();
    try {
      final result = await fetchExitInfo(client);
      if (running && generation == _exitInfoGeneration) exitInfo = result;
    } catch (e) {
      if (running && generation == _exitInfoGeneration) {
        exitInfoError = switch (e) {
          TimeoutException() => '出口检测超时，请重试',
          FormatException() => '出口信息格式无效，请重试',
          HandshakeException() => '出口检测 TLS 握手失败，请重试',
          SocketException() => '出口检测连接失败，请重试',
          HttpException() => e.message,
          _ => '出口检测失败，请重试',
        };
      }
    } finally {
      client.close(force: true);
      if (generation == _exitInfoGeneration) {
        _exitInfoClient = null;
        checkingExitInfo = false;
        notifyListeners();
      }
    }
  }

  bool get refreshingConnectionInfo =>
      checkingExitInfo || _connectionProbe?.generation == _pollGeneration;

  Future<void> refreshConnectionInfo() async {
    if (!running || busy || _disposed || refreshingConnectionInfo) return;
    await Future.wait([refreshExitInfo(), _refreshConnectionLatency()]);
  }

  Future<void> _refreshConnectionLatency() async {
    if (!running || busy || _disposed) return;
    final node = reportedNode;
    final tag = _effectiveTag;
    if (node == null || tag == null) return;
    final generation = _pollGeneration;
    final previous = _connectionProbe;
    if (previous?.generation == generation && previous?.tag == tag) return;
    final probe = _connectionProbe = (
      tag: tag,
      generation: generation,
      token: Object(),
    );
    notifyListeners();

    RuntimeTestResult? result;
    String? requestError;
    try {
      // A probe of the current node only updates its displayed latency.
      final results = await runtime.test([
        tag,
      ], settings.advancedOrDefault.urlTestUrl);
      result = results[tag];
    } catch (e) {
      requestError = _friendlyError(e);
    }
    if (_connectionProbe != probe) return;
    _connectionProbe = null;
    if (_disposed || !running || generation != _pollGeneration) return;
    if (identical(snapshot.nodeById(node.id), node)) {
      _saveNodeLatency(node.id, result, requestError);
    }
    notifyListeners();
  }

  Future<void> saveHomeLayout(
    HomeLayout layout, {
    required bool desktop,
  }) async {
    final source = snapshot;
    final previous = desktop ? settings.homeDesktop : settings.homeMobile;
    if (desktop) {
      settings.homeDesktop = layout;
    } else {
      settings.homeMobile = layout;
    }
    try {
      await storage.save(source);
    } catch (_) {
      final current = desktop
          ? source.settings.homeDesktop
          : source.settings.homeMobile;
      if (identical(snapshot, source) && identical(current, layout)) {
        if (desktop) {
          settings.homeDesktop = previous;
        } else {
          settings.homeMobile = previous;
        }
      }
      rethrow;
    }
    notifyListeners();
  }

  bool get canQueueNodeTest => !busy || _nodeTestRequests.isNotEmpty;

  bool get testingAllNodes =>
      testingNodes &&
      _nodeTestRequests.isNotEmpty &&
      _nodeTestRequests.keys.first == null;

  /// Includes both running and waiting requests. A null ID is the global request.
  bool isNodeTestRequested(String? groupId) =>
      _nodeTestRequests.containsKey(groupId);

  ProxyNode? get currentNode {
    return reportedNode ?? snapshot.nodeById(settings.manualNodeId);
  }

  /// Returns the URL subscription that owns the current node, or the sole URL
  /// subscription when no node is selected.
  Subscription? get currentSubscription {
    final node = currentNode;
    final subscriptionId = node?.subscriptionId;
    if (subscriptionId != null) {
      for (final subscription in snapshot.subscriptions) {
        if (subscription.id == subscriptionId &&
            subscription.isUrlSubscription) {
          return subscription;
        }
      }
      return null;
    }
    if (node != null) return null;
    final subscriptions = snapshot.subscriptions
        .where((subscription) => subscription.isUrlSubscription)
        .toList(growable: false);
    return subscriptions.length == 1 ? subscriptions.single : null;
  }

  ProxyNode? get reportedNode {
    if (!running) return null;
    return snapshot.nodeById(_nodeIdsByTag[_effectiveTag]);
  }

  String? nodeNameForOutboundTag(String outboundTag) {
    if (outboundTag.isEmpty) return null;
    return _connectionNodeNames[outboundTag];
  }

  String? nameForMatchedRule(int? index) => _compiled?.routeRuleNames[index];

  ProxyNode? get offlineRecommendedNode {
    if (_offlineTestDelays.isEmpty ||
        snapshot.useCustomConfig ||
        _offlineTestUrl != settings.advancedOrDefault.urlTestUrl) {
      return null;
    }
    ProxyNode? bestNode;
    int? bestDelay;
    for (final node in ConfigCompiler.autoCandidates(
      snapshot.allNodes,
      snapshot.subscriptions,
    )) {
      final delay = _offlineTestDelays[node];
      if (delay != null && (bestDelay == null || delay < bestDelay)) {
        bestNode = node;
        bestDelay = delay;
      }
    }
    return bestNode;
  }

  String get currentGroupLabel {
    if (settings.selectionMode == SelectionMode.auto) return '自动选择';
    return '手动选择';
  }

  String? get coreRunError => runtimeStatus?.error ?? error;

  Future<void> initialize() async {
    paths = await AppPaths.resolve();
    storage = AppStorage(paths);
    systemProxy = Platform.isWindows ? WindowsSystemProxy(paths) : null;
    final loaded = await storage.load();
    if (_disposed) return;
    snapshot = loaded.snapshot;
    appearanceTick.value++;
    ruleSets = RuleSetManager(
      paths: paths,
      clientFactory: _createManagedHttpClient,
      // Expert mode can save a copy of the generated paths in its JSON.
      isSnapshotReferenced: (directory) =>
          snapshot.customConfig.contains(directory) ||
          jsonEncode(snapshot.advancedJson).contains(directory),
    );
    loadWarning = loaded.warning;
    if (Platform.isAndroid) {
      settings.tunEnabled = true;
    }
    runtime = Platform.isAndroid
        ? AndroidRuntimeClient(paths)
        : WindowsRuntimeClient(paths);
    // Neither task needs results from the other. Both must finish before
    // the home page can compile a config or start a new core.
    await Future.wait([_initializeRuleSets(), _cleanupStaleRuntime()]);
    if (_disposed) return;
    if (systemProxy != null) {
      final restored = systemProxy!.restoreIfOwned();
      if (!restored.ok) {
        loadWarning = [
          loadWarning,
          restored.error,
        ].whereType<String>().join('\n');
      }
    }
    initialized = true;
    notifyListeners();
    unawaited(_autoUpdateSubscriptions(initial: true));
    _subscriptionTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      unawaited(_autoUpdateSubscriptions());
    });
    _ruleSetStartupTimer = Timer(const Duration(seconds: 8), () {
      unawaited(_autoUpdateRuleSets());
    });
    _ruleSetTimer = Timer.periodic(const Duration(hours: 6), (_) {
      unawaited(_autoUpdateRuleSets());
    });
    if (settings.autoConnect && hasNodes) {
      unawaited(connect());
    }
  }

  Future<void> _initializeRuleSets() async {
    try {
      await ruleSets.initialize();
      ruleSetStatus = await ruleSets.readStatus();
    } catch (e) {
      loadWarning = [
        loadWarning,
        '分流规则目录初始化失败：$e',
      ].whereType<String>().join('\n');
    }
  }

  Future<void> _cleanupStaleRuntime() async {
    try {
      await runtime.cleanupStale();
    } catch (error) {
      // The previous runtime may already be gone; startup can continue.
      debugPrint(
        'Could not clean up the previous runtime: ${error.runtimeType}',
      );
    }
  }

  Future<void> _autoUpdateSubscriptions({bool initial = false}) async {
    if (initial) {
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    final now = DateTime.now();
    for (final subscription in List<Subscription>.of(snapshot.subscriptions)) {
      if (!subscription.isAutoUpdateDue(now)) continue;
      try {
        await updateSubscription(subscription.id, silent: true);
      } catch (_) {}
    }
  }

  Future<void> _autoUpdateRuleSets() async {
    if (!settings.ruleSetAutoUpdate) return;
    final checkedAt = ruleSetStatus?.checkedAt;
    if (checkedAt != null &&
        DateTime.now().difference(checkedAt) < const Duration(hours: 24)) {
      return;
    }
    await updateRuleSets(automatic: true);
  }

  Future<void> updateRuleSets({bool automatic = false}) async {
    if (_ruleSetUpdatesStopped || updatingRuleSets) return;
    updatingRuleSets = true;
    ruleSetError = null;
    notifyListeners();
    try {
      final result = await ruleSets.update();
      ruleSetStatus = result.status;
      if (result.updated && (!automatic || running)) {
        notice = running ? '规则集已更新，重新连接后生效。' : '规则集已更新，将在下次连接时生效。';
      } else if (!automatic) {
        notice = '规则集已是最新。';
      }
    } catch (e) {
      ruleSetError = _friendlyError(e);
    } finally {
      updatingRuleSets = false;
      if (!_ruleSetUpdatesStopped) notifyListeners();
    }
  }

  Future<void> resetBuiltInRuleSets() async {
    if (_ruleSetUpdatesStopped || updatingRuleSets) return;
    updatingRuleSets = true;
    ruleSetError = null;
    notifyListeners();
    try {
      ruleSetStatus = await ruleSets.resetToBundled();
      notice = running ? '已恢复内置规则，重新连接后生效。' : '已恢复内置规则。';
    } catch (e) {
      ruleSetError = _friendlyError(e);
    } finally {
      updatingRuleSets = false;
      if (!_ruleSetUpdatesStopped) notifyListeners();
    }
  }

  AppUpdateService createUpdateService() =>
      AppUpdateService(() => IOClient(_createManagedHttpClient()));

  HttpClient _createManagedHttpClient() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    if (running) {
      final inbound = settings.inboundOrDefault;
      client.findProxy = (_) => 'PROXY 127.0.0.1:${inbound.localPort}';
      if (inbound.authUsername.isNotEmpty || inbound.authPassword.isNotEmpty) {
        client.addProxyCredentials(
          '127.0.0.1',
          inbound.localPort,
          'Basic',
          HttpClientBasicCredentials(
            inbound.authUsername,
            inbound.authPassword,
          ),
        );
      }
    }
    return client;
  }

  String get ruleSetVersionLabel {
    final updated = ruleSetStatus?.updatedAt;
    if (updated == null) return ruleSetStatus?.sourceLabel ?? '内置';
    final local = updated.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$month-$day';
  }

  CompiledConfig compile() {
    return ConfigCompiler.compile(
      snapshot,
      target: Platform.isAndroid
          ? CompileTarget.android
          : CompileTarget.windows,
      cachePath: '${paths.runtime.path}${Platform.pathSeparator}cache.db',
      logPath: paths.logFile.path,
      systemDnsServers: _systemDns,
      ruleSetPaths: ruleSets.pathsByTag,
    );
  }

  Future<CompiledConfig> compileForExport() async {
    final compiled = compile();
    await ruleSets.prepareLocalFiles(compiled.localRuleSetPaths);
    return compiled;
  }

  /// The physical network can change between sessions, so refresh the servers
  /// right before a config is compiled for the engine.
  Future<void> _refreshSystemDns() async {
    try {
      _systemDns = await runtime.systemDnsServers();
    } catch (_) {
      _systemDns = const [];
    }
  }

  Future<void> connect() async {
    if (busy || running) return;
    if (!hasNodes) {
      _setError('还没有可用节点，请先导入订阅或节点。');
      return;
    }
    if (Platform.isAndroid &&
        settings.perAppMode == PerAppMode.allow &&
        settings.perAppPackages.isEmpty) {
      _setError('分应用代理已选择“仅所选”，但还没有勾选任何应用。');
      return;
    }
    busy = true;
    error = null;
    notice = null;
    _unexpectedStop = false;
    _cancelNodeTests();
    await _stopTemporaryTestRuntime();
    notifyListeners();
    try {
      await _refreshSystemDns();
      ruleSets.pinActiveSnapshotForCore();
      final compiled = compile();
      await ruleSets.prepareLocalFiles(compiled.localRuleSetPaths);
      _compiled = compiled;
      final namesById = <String, String>{};
      for (final subscription in snapshot.subscriptions) {
        for (final node in subscription.nodes) {
          namesById.putIfAbsent(node.id, () => node.name);
        }
      }
      final connectionNodeNames = <String, String>{};
      final nodeIdsByTag = <String, String>{};
      for (final entry in compiled.nodeTags.entries) {
        nodeIdsByTag[entry.value] = entry.key;
        final name = namesById[entry.key];
        if (name != null && name.isNotEmpty) {
          connectionNodeNames[entry.value] = name;
        }
      }
      _connectionNodeNames = connectionNodeNames;
      _nodeIdsByTag = nodeIdsByTag;
      _effectiveTag = null;
      if (compiled.warnings.isNotEmpty) notice = compiled.warnings.first;
      final tunMode =
          Platform.isWindows && (settings.tunEnabled || compiled.hasTunInbound);
      await runtime.start(
        config: compiled.encoded,
        mode: tunMode ? 'tun' : 'normal',
        perAppMode: settings.perAppMode.name,
        perAppPackages: settings.perAppPackages,
      );
      running = true;
      connectedAt = DateTime.now();
      // sing-box restores a group's last selection from its cache file, which
      // would silently override the node chosen in the app before connecting.
      if (settings.selectionMode == SelectionMode.manual) {
        final tag = compiled.nodeTags[settings.manualNodeId];
        if (tag != null) {
          try {
            await runtime.select(tag);
          } catch (_) {}
        }
      }
      _lastUpTotal = 0;
      _lastDownTotal = 0;
      _lastTrafficAt = null;
      samples = const [];
      _recordHomeActivity('代理已连接');
      _startPolling();
      try {
        await _refreshStatus();
      } catch (_) {
        // Status is best effort; the poll loop retries and reports a stop.
      }
      if (settings.systemProxyEnabled && systemProxy != null) {
        final result = systemProxy!.enable(settings.inboundOrDefault.localPort);
        if (!result.ok) {
          error = result.error;
          settings.systemProxyEnabled = false;
        }
      }
    } catch (e) {
      running = false;
      _cancelExitInfo();
      _recordHomeActivity('代理连接失败', failed: true);
      _pollTimer?.cancel();
      _uiTimer?.cancel();
      _setError(_friendlyError(e));
      systemProxy?.disable();
      // A timed-out start can still own a live VpnService/TUN; tear it down so
      // the device is never left routing traffic into a dead engine.
      await runtime.shutdown();
    } finally {
      busy = false;
      notifyListeners();
      if (running && !checkingExitInfo && exitInfo == null) {
        unawaited(refreshExitInfo());
      }
      unawaited(_refreshConnectionLatency());
      await storage.save(snapshot);
    }
  }

  Future<void> disconnect({bool silent = false}) async {
    _cancelExitInfo();
    final wasRunning = running;
    _pollTimer?.cancel();
    _pollTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;
    _pollGeneration++;
    _invalidateConnectionRefresh();
    _cancelNodeTests();
    _polling = false;
    _pollFailures = 0;
    await _stopTemporaryTestRuntime();
    if (!running && !silent) {
      notifyListeners();
      await runtime.shutdown();
      _connectionNodeNames = const {};
      _nodeIdsByTag = const {};
      return;
    }
    busy = true;
    if (!silent) notifyListeners();
    try {
      systemProxy?.disable();
      await runtime.shutdown();
    } catch (e) {
      if (!silent) _setError(_friendlyError(e));
    } finally {
      running = false;
      _cancelExitInfo();
      runtimeStatus = null;
      traffic = const RuntimeTraffic();
      connections = const [];
      samples = const [];
      _connectionNodeNames = const {};
      _nodeIdsByTag = const {};
      _effectiveTag = null;
      connectedAt = null;
      if (wasRunning) _recordHomeActivity('代理已断开');
      busy = false;
      notifyListeners();
    }
  }

  Future<void> toggleConnection() async {
    if (running) {
      await disconnect();
    } else {
      await connect();
    }
  }

  Future<void> restartCore() async {
    if (_rebuilding) return;
    _rebuilding = true;
    try {
      final wasRunning = running;
      await disconnect(silent: true);
      if (wasRunning) await connect();
    } finally {
      _rebuilding = false;
    }
  }

  Future<List<InstalledApp>> installedApps() => runtime.installedApps();

  Future<void> updatePerApp(PerAppMode mode, List<String> packages) async {
    settings.perAppMode = mode;
    settings.perAppPackages = List.of(packages);
    await storage.save(snapshot);
    notifyListeners();
  }

  Future<void> setSplitMode(SplitMode mode) async {
    final previous = settings.splitMode;
    if (!canChangeSplitMode || previous == mode) return;
    _changingSplitMode = true;
    settings.splitMode = mode;
    notifyListeners();
    try {
      try {
        await storage.save(snapshot);
      } catch (error) {
        settings.splitMode = previous;
        if (!_disposed) _setError('规则模式保存失败：${_friendlyError(error)}');
        return;
      }
      if (!_disposed && running) await restartCore();
    } finally {
      _changingSplitMode = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> setSelectionMode(SelectionMode mode) async {
    if (settings.selectionMode == mode) return;
    settings.selectionMode = mode;
    await storage.save(snapshot);
    notifyListeners();
    if (running) await restartCore();
  }

  Future<void> selectNode(String nodeId) async {
    final node = snapshot.nodeById(nodeId);
    if (node == null) return;
    final wasAuto = settings.selectionMode == SelectionMode.auto;
    settings.manualNodeId = nodeId;
    settings.selectionMode = SelectionMode.manual;
    await storage.save(snapshot);
    notifyListeners();
    if (running) {
      if (wasAuto) {
        await restartCore();
      } else {
        final tag = _compiled?.nodeTags[nodeId] ?? ConfigCompiler.nodeTag(node);
        try {
          await runtime.select(tag);
          _effectiveTag = tag;
          unawaited(refreshExitInfo());
          unawaited(_refreshConnectionLatency());
          await _refreshStatus();
        } catch (e) {
          _setError('切换节点失败：${_friendlyError(e)}');
        }
      }
    }
  }

  Future<void> toggleAutoCandidate(String nodeId) async {
    final node = snapshot.nodeById(nodeId);
    if (node == null) return;
    node.autoEnabled = !node.autoEnabled;
    await storage.save(snapshot);
    notifyListeners();
    if (running && settings.selectionMode == SelectionMode.auto) {
      await restartCore();
    }
  }

  Future<void> toggleGroupAutoCandidate(String groupId) async {
    final index = snapshot.subscriptions.indexWhere(
      (group) => group.id == groupId,
    );
    if (index < 0) return;
    final group = snapshot.subscriptions[index];
    group.autoEnabled = !group.autoEnabled;
    await storage.save(snapshot);
    notifyListeners();
    if (running && settings.selectionMode == SelectionMode.auto) {
      await restartCore();
    }
  }

  Future<void> toggleFavorite(String nodeId) async {
    final node = snapshot.nodeById(nodeId);
    if (node == null) return;
    node.favorite = !node.favorite;
    await storage.save(snapshot);
    notifyListeners();
  }

  Future<void> setSystemProxy(bool enabled) async {
    if (!supportsSystemProxy) return;
    settings.systemProxyEnabled = enabled;
    await storage.save(snapshot);
    notifyListeners();
    if (enabled) {
      if (!running) {
        await connect();
      } else {
        final result = systemProxy!.enable(settings.inboundOrDefault.localPort);
        if (!result.ok) {
          settings.systemProxyEnabled = false;
          _setError(result.error ?? '设置系统代理失败');
          await storage.save(snapshot);
        }
      }
    } else {
      final result = systemProxy!.disable();
      if (!result.ok) _setError(result.error ?? '恢复系统代理失败');
    }
    notifyListeners();
  }

  Future<void> setTun(bool enabled) async {
    if (settings.tunEnabled == enabled) return;
    final wasRunning = running;
    settings.tunEnabled = enabled;
    await storage.save(snapshot);
    notifyListeners();
    if (!Platform.isAndroid && running) {
      await restartCore();
      if (wasRunning && !running) {
        settings.tunEnabled = !enabled;
        await storage.save(snapshot);
        await connect();
        error ??= enabled ? 'TUN 未能启动，已恢复原接管方式。' : '已恢复连接。';
        notifyListeners();
      }
    } else if (Platform.isAndroid) {
      if (enabled && !running) {
        await connect();
      } else if (!enabled && running) {
        await disconnect();
      }
    }
  }

  Future<void> updateInbound(
    InboundSettings Function(InboundSettings) change,
  ) async {
    final value = settings.inboundOrDefault;
    change(value);
    settings.inbound = value;
    await storage.save(snapshot);
    notifyListeners();
    if (running) await restartCore();
  }

  Future<void> updateTun(TunSettings Function(TunSettings) change) async {
    final value = settings.tunOrDefault;
    change(value);
    settings.tun = value;
    await storage.save(snapshot);
    notifyListeners();
    if (running && supportsTun) await restartCore();
  }

  Future<void> updateDns(DnsSettings Function(DnsSettings) change) async {
    final value = settings.dnsOrDefault;
    change(value);
    settings.dns = value;
    await storage.save(snapshot);
    notifyListeners();
    if (running) await restartCore();
  }

  Future<void> updateAdvanced(
    AdvancedSettings Function(AdvancedSettings) change, {
    bool restart = false,
  }) async {
    final value = settings.advancedOrDefault;
    change(value);
    settings.advanced = value;
    await storage.save(snapshot);
    notifyListeners();
    if (restart && running) await restartCore();
  }

  Future<void> saveRules(List<RoutingRule> rules) async {
    snapshot.rules = rules;
    await storage.save(snapshot);
    notifyListeners();
    if (running) await restartCore();
  }

  Future<void> saveAdvancedJson(Map<String, dynamic> json) async {
    final probe = Map<String, dynamic>.from(json);
    final violations = ConfigPolicy.validate(probe);
    if (violations.isNotEmpty) {
      _setError(
        '高级 JSON 包含被禁止的设置：${violations.map((e) => e.message).join('；')}',
      );
      return;
    }
    snapshot.advancedJson = json;
    await storage.save(snapshot);
    notifyListeners();
    if (running) await restartCore();
  }

  Future<void> setCustomConfig(String config, bool useCustom) async {
    if (useCustom) {
      final violations = ConfigPolicy.validateText(config);
      if (violations.isNotEmpty) {
        _setError('自定义配置被拒绝：${violations.map((e) => e.message).join('；')}');
        return;
      }
    }
    snapshot.customConfig = config;
    snapshot.useCustomConfig = useCustom;
    await storage.save(snapshot);
    notifyListeners();
    if (running) await restartCore();
  }

  Future<void> verifyConfig() async {
    try {
      final compiled = compile();
      notice = compiled.warnings.isEmpty
          ? '配置校验通过'
          : compiled.warnings.join('；');
      error = null;
    } catch (e) {
      _setError(_friendlyError(e));
    }
    notifyListeners();
  }

  Future<void> _stopTemporaryTestRuntime() async {
    if (!_temporaryTestRuntime) return;
    _temporaryTestRuntime = false;
    try {
      await runtime.stopTest();
    } catch (_) {}
  }

  void queueNodeTest(Iterable<ProxyNode> nodes, {String? groupId}) {
    if (!canQueueNodeTest || isNodeTestRequested(groupId)) return;
    final nodeIds = {for (final node in nodes) node.id};
    if (nodeIds.isEmpty) return;
    _nodeTestRequests[groupId] = nodeIds;
    notifyListeners();
    if (!_drainingNodeTests) {
      unawaited(_drainNodeTests());
    }
  }

  Future<void> _drainNodeTests() async {
    _drainingNodeTests = true;
    try {
      while (_nodeTestRequests.isNotEmpty) {
        final MapEntry(key: groupId, value: nodeIds) =
            _nodeTestRequests.entries.first;
        try {
          // Use the current configuration for nodes still present when their turn starts.
          await testNodes(
            nodes: snapshot.allNodes.where((node) => nodeIds.contains(node.id)),
          );
        } catch (error) {
          if (identical(_nodeTestRequests[groupId], nodeIds)) {
            _setError(_friendlyError(error));
          }
        } finally {
          if (identical(_nodeTestRequests[groupId], nodeIds)) {
            _nodeTestRequests.remove(groupId);
            notifyListeners();
          }
        }
      }
    } finally {
      _drainingNodeTests = false;
    }
  }

  void _cancelNodeTests() {
    _testGeneration++;
    testingNodes = false;
    _nodeTestRequests.clear();
  }

  Future<void> testNodes({Iterable<ProxyNode>? nodes}) async {
    if (testingNodes || busy) return;
    final candidates = (nodes ?? snapshot.allNodes).toList();
    if (candidates.isEmpty) return;
    final temporary = !running;
    CompiledConfig? testCompiled;
    if (temporary) {
      if (snapshot.useCustomConfig) {
        _setError('完整自定义配置没有可映射的节点标签，请先连接后再测速。');
        return;
      }
      final generation = _testGeneration;
      try {
        await _refreshSystemDns();
        if (generation != _testGeneration || testingNodes || busy || running) {
          return;
        }
        testCompiled = ConfigCompiler.compile(
          snapshot,
          target: Platform.isAndroid
              ? CompileTarget.android
              : CompileTarget.windows,
          cachePath: '${paths.runtime.path}${Platform.pathSeparator}cache.db',
          testOnly: true,
          systemDnsServers: _systemDns,
        );
      } catch (e) {
        _setError(_friendlyError(e));
        return;
      }
    }
    final run = ++_testGeneration;
    final compiledTags = (testCompiled ?? _compiled)?.nodeTags;
    final queue = {for (final node in candidates) node.id: node}.values
        .toList();
    final roundDelays = <String, int?>{};
    final offlineDelays = <ProxyNode, int>{};
    final url = settings.advancedOrDefault.urlTestUrl;
    testingNodes = true;
    testCompleted = 0;
    testTotal = queue.length;
    if (temporary) {
      _temporaryTestRuntime = true;
      busy = true;
    }
    notifyListeners();
    if (temporary) {
      try {
        await runtime.startTest(config: testCompiled!.encoded);
      } catch (e) {
        if (run == _testGeneration) {
          _temporaryTestRuntime = false;
          testingNodes = false;
          _setError('测速核心启动失败：${_friendlyError(e)}');
        }
        try {
          await runtime.stopTest();
        } catch (_) {}
        busy = false;
        notifyListeners();
        return;
      } finally {
        busy = false;
      }
      if (run != _testGeneration || !_temporaryTestRuntime) return;
      notifyListeners();
    }
    Future<void> testNode(ProxyNode node) async {
      final tag = compiledTags?[node.id] ?? ConfigCompiler.nodeTag(node);
      RuntimeTestResult? value;
      String? requestError;
      try {
        final results = await runtime.test([tag], url);
        value = results[tag];
      } catch (e) {
        requestError = _friendlyError(e);
      }
      if (run != _testGeneration) return;
      final delay = value?.delay;
      if (value != null) roundDelays[tag] = delay;
      _saveNodeLatency(node.id, value, requestError);
      if (delay != null &&
          temporary &&
          (compiledTags?.containsKey(node.id) ?? false)) {
        offlineDelays[node] = delay;
      }
      testCompleted++;
      notifyListeners();
    }

    final pending = <Future<void>>{};
    for (final node in queue) {
      if (pending.length >= _latencyTestConcurrency) {
        await Future.any(pending);
      }
      if (run != _testGeneration || !(running || _temporaryTestRuntime)) break;
      late final Future<void> probe;
      probe = testNode(node).whenComplete(() => pending.remove(probe));
      pending.add(probe);
    }
    await Future.wait(pending);
    if (run != _testGeneration) return;
    try {
      await _stopTemporaryTestRuntime();
      if (run != _testGeneration) return;
      if (temporary) {
        _offlineTestDelays
          ..clear()
          ..addAll(offlineDelays);
        _offlineTestUrl = url;
      } else if (running &&
          settings.selectionMode == SelectionMode.auto &&
          !snapshot.useCustomConfig) {
        await _refreshAutoSelection(roundDelays);
      }
    } finally {
      if (run == _testGeneration) {
        testingNodes = false;
        notifyListeners();
      }
    }
  }

  void _saveNodeLatency(
    String nodeId,
    RuntimeTestResult? result,
    String? requestError,
  ) {
    final delay = result?.delay;
    if (delay != null) {
      _latencies[nodeId] = delay;
      _latencyErrors.remove(nodeId);
    } else {
      final message = result?.error?.trim();
      _latencyErrors[nodeId] =
          requestError ??
          (message == null || message.isEmpty ? '测速失败' : message);
    }
  }

  Future<void> _refreshAutoSelection(Map<String, int?> delays) async {
    final generation = _pollGeneration;
    try {
      await runtime.refreshAuto(delays);
      if (!running || generation != _pollGeneration) return;
      await _refreshStatus();
    } catch (error) {
      if (running && generation == _pollGeneration) {
        _setError('自动选点更新失败：${_friendlyError(error)}');
      }
    }
  }

  bool get serviceCheckBusy => _servicesChecking.isNotEmpty;

  bool isServiceChecking(String id) => _servicesChecking.contains(id);

  bool get checksViaTun =>
      running &&
      (Platform.isAndroid
          ? settings.perAppMode != PerAppMode.allow
          : settings.tunEnabled);

  bool get checksViaProxy => running && !checksViaTun;

  Future<void> checkServiceStatus({String? id}) async {
    if (_disposed) return;
    final targets = <ConnectivityService>[];
    if (id == null) {
      targets.addAll(
        connectivityServices.where(
          (service) => !_servicesChecking.contains(service.id),
        ),
      );
    } else {
      for (final service in connectivityServices) {
        if (service.id == id && !_servicesChecking.contains(id)) {
          targets.add(service);
        }
      }
    }
    if (targets.isEmpty) return;
    final viaTun = checksViaTun;
    final viaProxy = checksViaProxy;
    final inbound = settings.inboundOrDefault;
    for (final service in targets) {
      _servicesChecking.add(service.id);
      serviceChecks[service.id] = ServiceCheckResult(
        status: ServiceCheckStatus.checking,
        viaProxy: viaProxy,
        viaTun: viaTun,
        checkedAt: serviceChecks[service.id]?.checkedAt,
      );
    }
    notifyListeners();
    final results = await Future.wait(
      targets.map((service) async {
        final result = await probeConnectivityService(
          service,
          viaProxy: viaProxy,
          viaTun: viaTun,
          proxyPort: inbound.localPort,
          username: inbound.authUsername,
          password: inbound.authPassword,
        );
        return MapEntry(service.id, result);
      }),
    );
    if (_disposed) return;
    final addresses = results
        .where((entry) => entry.value.isAvailable)
        .map((entry) => entry.value.address)
        .whereType<String>()
        .toSet();
    final addressClient = addresses.isEmpty ? null : _createManagedHttpClient();
    if (addressClient != null) _serviceAddressClients.add(addressClient);
    try {
      final info = addressClient == null
          ? const <String, IpAttribution>{}
          : await fetchServiceAddressInfo(addressClient, addresses);
      if (_disposed) return;
      for (final entry in results) {
        final attribution = entry.value.isAvailable
            ? info[entry.value.address]
            : null;
        serviceChecks[entry.key] = attribution == null
            ? entry.value
            : entry.value.withAddressInfo(attribution);
      }
    } finally {
      if (addressClient != null) _serviceAddressClients.remove(addressClient);
      for (final entry in results) {
        _servicesChecking.remove(entry.key);
      }
      if (!_disposed) notifyListeners();
    }
  }

  /// Starts automatic refresh for a mounted connections view.
  VoidCallback watchConnections() {
    if (_connectionViewers++ == 0) _startConnectionPolling();
    var watching = true;
    return () {
      if (!watching) return;
      watching = false;
      if (--_connectionViewers == 0) _invalidateConnectionRefresh();
    };
  }

  void _startConnectionPolling() {
    if (!running || _disposed || _connectionViewers == 0) return;
    _connectionsTimer?.cancel();
    unawaited(refreshConnections());
    _connectionsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(refreshConnections());
    });
  }

  void _invalidateConnectionRefresh({bool stopTimer = true}) {
    if (stopTimer) {
      _connectionsTimer?.cancel();
      _connectionsTimer = null;
    }
    _connectionRefreshToken = null;
    _connectionRefresh = null;
  }

  Future<void> refreshConnections() {
    if (!running || _disposed) return Future<void>.value();
    final pending = _connectionRefresh;
    if (pending != null) return pending;
    final generation = _pollGeneration;
    final token = _connectionRefreshToken = Object();
    return _connectionRefresh = _fetchConnections(generation, token);
  }

  Future<void> _fetchConnections(int generation, Object token) async {
    try {
      final nextConnections = await Future.sync(runtime.fetchConnections);
      if (!running ||
          generation != _pollGeneration ||
          !identical(token, _connectionRefreshToken)) {
        return;
      }
      connections = nextConnections;
    } catch (error) {
      // Keep the last snapshot on transient failures; the next poll retries.
      assert(() {
        debugPrint('Connection refresh failed: ${error.runtimeType}');
        return true;
      }());
    } finally {
      if (identical(token, _connectionRefreshToken)) {
        _invalidateConnectionRefresh(stopTimer: false);
      }
    }
  }

  Future<void> closeConnection(String id) async {
    if (!running || _disposed || !_closingConnectionIds.add(id)) return;
    final generation = _pollGeneration;
    try {
      await runtime.closeConnection(id);
      if (!running || _disposed || generation != _pollGeneration) return;
      _invalidateConnectionRefresh(stopTimer: false);
      connections = [
        for (final item in connections)
          if (item.id != id) item,
      ];
      await refreshConnections();
    } catch (error) {
      if (running && !_disposed && generation == _pollGeneration) {
        _setError('关闭连接失败：${_friendlyError(error)}');
      }
    } finally {
      _closingConnectionIds.remove(id);
    }
  }

  Future<void> clearConnections() async {
    if (!running) return;
    final generation = _pollGeneration;
    try {
      await runtime.clearConnections();
      if (!running || generation != _pollGeneration) return;
      _invalidateConnectionRefresh(stopTimer: false);
      await refreshConnections();
    } catch (e) {
      _setError(_friendlyError(e));
    }
  }

  Future<Subscription> importFromUrl({
    required String url,
    String? name,
    String userAgent = '',
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const ParseException('订阅链接必须是 http 或 https');
    }
    final response = await _fetchSubscription(uri, userAgent: userAgent);
    final headers = SubscriptionHeaders.from(response.headers);
    final id = _newId();
    final parsed = await ProfileParser.parseInBackground(
      response.body,
      headers: headers,
      subscriptionId: id,
    );
    final subscription = Subscription(
      id: id,
      name: name?.trim().isNotEmpty == true
          ? name!.trim()
          : (headers.profileTitle ?? uri.host),
      url: uri.toString(),
      userAgent: userAgent,
      updateIntervalMinutes:
          parsed.updateIntervalMinutes ??
          Subscription.defaultUpdateIntervalMinutes,
      lastUpdated: DateTime.now(),
      uploadBytes: parsed.uploadBytes,
      downloadBytes: parsed.downloadBytes,
      totalBytes: parsed.totalBytes,
      expireAt: parsed.expireAt,
      nodes: parsed.nodes,
      rawFormat: parsed.format,
    );
    snapshot.subscriptions.add(subscription);
    if (settings.manualNodeId == null && parsed.nodes.isNotEmpty) {
      settings.manualNodeId = parsed.nodes.first.id;
    }
    await storage.save(snapshot);
    notifyListeners();
    return subscription;
  }

  Future<int> importNodesToGroup(String groupId, String content) async {
    final source = snapshot;
    Subscription localGroup() {
      final group = source.subscriptions
          .where((item) => item.id == groupId)
          .firstOrNull;
      if (_disposed || !identical(snapshot, source) || group == null) {
        throw const ParseException('分组不存在');
      }
      if (group.isUrlSubscription) {
        throw const ParseException('订阅分组的节点由订阅维护，请更新订阅或添加到节点集合');
      }
      return group;
    }

    localGroup();
    final parsed = await ProfileParser.parseInBackground(
      content,
      subscriptionId: groupId,
    );
    final group = localGroup();
    final known = {
      for (final node in group.nodes)
        ProfileParser.fingerprintOf(node.outbound),
    };
    final added = [
      for (final node in parsed.nodes)
        if (known.add(ProfileParser.fingerprintOf(node.outbound))) node,
    ];
    if (added.isEmpty) throw const ParseException('该分组中已存在这些节点');
    group.nodes = <ProxyNode>[...group.nodes, ...added];
    settings.manualNodeId ??= added.first.id;
    await storage.save(snapshot);
    notifyListeners();
    if (running) await restartCore();
    return added.length;
  }

  Future<Subscription> createGroup(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const ParseException('分组名称不能为空');
    if (snapshot.subscriptions.any((group) => group.name == trimmed)) {
      throw const ParseException('已存在同名分组');
    }
    final group = Subscription(id: _newId(), name: trimmed);
    snapshot.subscriptions.add(group);
    await storage.save(snapshot);
    notifyListeners();
    return group;
  }

  /// Reorders the visible subscriptions while preserving other group slots.
  Future<void> reorderSubscriptions(List<String> orderedIds) async {
    final source = snapshot;
    final previous = source.subscriptions;
    final visibleIds = orderedIds.toSet();
    final visibleById = {
      for (final group in previous)
        if (group.isUrlSubscription && visibleIds.contains(group.id))
          group.id: group,
    };
    if (visibleById.length != orderedIds.length) return;

    var nextIndex = 0;
    final reordered = [
      for (final group in previous)
        if (visibleById.containsKey(group.id))
          visibleById[orderedIds[nextIndex++]] ?? group
        else
          group,
    ];
    if (listEquals(previous, reordered)) return;
    source.subscriptions = List.of(reordered);
    try {
      await storage.save(source);
    } catch (exception) {
      if (!identical(snapshot, source)) return;
      if (listEquals(source.subscriptions, reordered)) {
        source.subscriptions = previous;
      }
      _setError('订阅顺序保存失败：${_friendlyError(exception)}');
      return;
    }
    if (identical(snapshot, source)) notifyListeners();
  }

  Future<void> updateGroupPreferences(
    String id, {
    String? includeFilter,
    String? excludeFilter,
    NodeSortMode? sortMode,
    bool? sortDescending,
  }) async {
    final index = snapshot.subscriptions.indexWhere((group) => group.id == id);
    if (index < 0) return;
    final group = snapshot.subscriptions[index];
    if (includeFilter != null) group.includeFilter = includeFilter;
    if (excludeFilter != null) group.excludeFilter = excludeFilter;
    if (sortMode != null) group.sortMode = sortMode;
    if (sortDescending != null) group.sortDescending = sortDescending;
    await storage.save(snapshot);
    notifyListeners();
  }

  Future<void> updateSubscriptionInfo(
    String id, {
    required String name,
    required String url,
    required String userAgent,
    bool? autoUpdate,
    int? updateIntervalMinutes,
  }) async {
    final index = snapshot.subscriptions.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) throw const ParseException('订阅名称不能为空');
    final trimmedUrl = url.trim();
    if (trimmedUrl.isNotEmpty) {
      final uri = Uri.tryParse(trimmedUrl);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
        throw const ParseException('订阅链接必须是 http 或 https');
      }
    }
    if (updateIntervalMinutes != null &&
        (updateIntervalMinutes < Subscription.minimumUpdateIntervalMinutes ||
            updateIntervalMinutes >
                Subscription.maximumUpdateIntervalMinutes)) {
      throw const ParseException('更新周期必须在 30 分钟到 30 天之间');
    }
    final existing = snapshot.subscriptions[index];
    final trimmedUserAgent = userAgent.trim();
    if (existing.url != trimmedUrl || existing.userAgent != trimmedUserAgent) {
      _subscriptionUpdates.remove(id);
    }
    snapshot.subscriptions[index] = existing.copyWith(
      name: trimmedName,
      url: trimmedUrl,
      userAgent: trimmedUserAgent,
      autoUpdate: autoUpdate,
      updateIntervalMinutes: updateIntervalMinutes,
      clearError: true,
    );
    await storage.save(snapshot);
    notifyListeners();
  }

  Future<void> updateSubscription(String id, {bool silent = false}) async {
    final sourceSnapshot = snapshot;
    final existing = sourceSnapshot.subscriptions
        .where((group) => group.id == id)
        .firstOrNull;
    if (existing == null) return;
    if (existing.url.isEmpty) {
      if (!silent) _setError('该订阅没有更新链接');
      return;
    }
    final request = Object();
    _subscriptionUpdates[id] = request;

    Subscription? currentSubscription() {
      if (_disposed ||
          !identical(snapshot, sourceSnapshot) ||
          !identical(_subscriptionUpdates[id], request)) {
        return null;
      }
      return snapshot.subscriptions
          .where((group) => group.id == id)
          .firstOrNull;
    }

    try {
      final response = await _fetchSubscription(
        Uri.parse(existing.url),
        userAgent: existing.userAgent,
      );
      if (currentSubscription() == null) return;
      final headers = SubscriptionHeaders.from(response.headers);
      final parsed = await ProfileParser.parseInBackground(
        response.body,
        headers: headers,
        subscriptionId: existing.id,
      );
      final current = currentSubscription();
      if (current == null) return;
      // The server interval only seeds new imports; refreshing must not
      // overwrite the per-subscription schedule configured by the user.
      final oldByFingerprint = <String, ProxyNode>{};
      for (final node in current.nodes) {
        oldByFingerprint[ProfileParser.fingerprintOf(node.outbound)] = node;
      }
      final merged = <ProxyNode>[];
      for (final node in parsed.nodes) {
        final previous =
            oldByFingerprint[ProfileParser.fingerprintOf(node.outbound)];
        if (previous != null) {
          merged.add(
            previous.copyWith(
              name: node.name,
              tag: node.tag,
              outbound: node.outbound,
            ),
          );
        } else {
          merged.add(node);
        }
      }
      current
        ..nodes = merged
        ..lastUpdated = DateTime.now()
        ..lastError = null
        ..uploadBytes = parsed.uploadBytes
        ..downloadBytes = parsed.downloadBytes
        ..totalBytes = parsed.totalBytes
        ..expireAt = parsed.expireAt;
      final selectedBefore = settings.manualNodeId;
      final selectionLost =
          selectedBefore != null && snapshot.nodeById(selectedBefore) == null;
      if (selectionLost) {
        settings.manualNodeId = null;
      }
      await storage.save(snapshot);
      if (!identical(snapshot, sourceSnapshot)) return;
      _recordHomeActivity('订阅更新完成，共 ${parsed.nodes.length} 个节点');
      notifyListeners();
      if (selectionLost) {
        if (running) await disconnect(silent: true);
        error = '原选中节点已从订阅移除，请重新选择节点。';
        notifyListeners();
      } else if (running) {
        await restartCore();
      }
      final completed = currentSubscription();
      if (!silent && completed != null) {
        notice = '「${completed.name}」已更新，共 ${parsed.nodes.length} 个节点';
        notifyListeners();
      }
    } catch (e) {
      final current = currentSubscription();
      if (current == null) return;
      current.lastError = _friendlyError(e);
      _recordHomeActivity('订阅更新失败', failed: true);
      await storage.save(snapshot);
      notifyListeners();
      if (!silent && currentSubscription() != null) {
        _setError('订阅更新失败：${current.lastError}');
      }
    } finally {
      if (identical(_subscriptionUpdates[id], request)) {
        _subscriptionUpdates.remove(id);
      }
    }
  }

  Future<http.Response> _fetchSubscription(
    Uri uri, {
    required String userAgent,
  }) async {
    final inbound = settings.inboundOrDefault;
    final raw = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    if (running) {
      raw.findProxy = (_) => 'PROXY 127.0.0.1:${inbound.localPort}';
      if (inbound.authUsername.isNotEmpty || inbound.authPassword.isNotEmpty) {
        raw.addProxyCredentials(
          '127.0.0.1',
          inbound.localPort,
          'Basic',
          HttpClientBasicCredentials(
            inbound.authUsername,
            inbound.authPassword,
          ),
        );
      }
    }
    final client = IOClient(raw);
    try {
      final request = http.Request('GET', uri);
      request.headers['User-Agent'] = userAgent.isEmpty
          ? 'NekoProxy/1.0 (sing-box)'
          : userAgent;
      request.headers['Accept'] = 'application/json, text/plain, */*';
      final streamed = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      final bytes = <int>[];
      await for (final chunk in streamed.stream.timeout(
        const Duration(seconds: 30),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 20 * 1024 * 1024) {
          throw const ParseException('订阅内容超过 20 MB，已拒绝');
        }
      }
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw ParseException('订阅服务器返回 HTTP ${streamed.statusCode}');
      }
      final contentType = streamed.headers['content-type'] ?? '';
      if (contentType.contains('text/html')) {
        throw const ParseException('订阅返回了网页而不是节点数据');
      }
      return http.Response.bytes(
        bytes,
        streamed.statusCode,
        headers: streamed.headers,
        request: streamed.request,
      );
    } on SocketException catch (error) {
      final message = _friendlyError(error);
      throw ParseException(message == error.toString() ? '无法连接订阅服务器' : message);
    } on http.ClientException {
      throw const ParseException('订阅请求失败，请检查网络和订阅链接');
    } on HttpException {
      throw const ParseException('订阅服务器返回了无效的 HTTP 响应');
    } on HandshakeException {
      throw const ParseException('订阅服务器 TLS 握手失败');
    } finally {
      client.close();
    }
  }

  Future<void> deleteSubscription(String id) async {
    _subscriptionUpdates.remove(id);
    final removed = snapshot.subscriptions.where((e) => e.id == id).toList();
    final ids = removed.expand((e) => e.nodes.map((n) => n.id)).toSet();
    snapshot.subscriptions.removeWhere((e) => e.id == id);
    final selectionLost =
        settings.manualNodeId != null && ids.contains(settings.manualNodeId);
    if (selectionLost) {
      settings.manualNodeId = null;
      error = '当前节点随分组一起删除，请重新选择节点。';
    }
    await storage.save(snapshot);
    notifyListeners();
    if (running && ids.isNotEmpty) {
      if (selectionLost && settings.selectionMode == SelectionMode.manual) {
        await disconnect(silent: true);
      } else {
        await restartCore();
      }
    }
  }

  Future<ProxyNode> addNodeLink(String link, {String? groupId}) async {
    final parsed = ProfileParser.parseLink(link);
    if (parsed == null) throw const ParseException('节点链接无效');
    Subscription? group;
    if (groupId != null) {
      for (final item in snapshot.subscriptions) {
        if (item.id == groupId) {
          group = item;
          break;
        }
      }
    }
    if (group?.isUrlSubscription == true) {
      throw const ParseException('订阅分组的节点由订阅维护，请更新订阅或添加到节点集合');
    }
    group ??= snapshot.subscriptions
        .where((e) => !e.isUrlSubscription)
        .firstOrNull;
    if (group == null) {
      group = Subscription(id: 'local', name: '手动添加', nodes: []);
      snapshot.subscriptions.add(group);
    }
    final node = parsed.copyWith(subscriptionId: group.id);
    group.nodes = <ProxyNode>[...group.nodes, node];
    settings.manualNodeId ??= node.id;
    await storage.save(snapshot);
    notifyListeners();
    if (running) await restartCore();
    return node;
  }

  Future<void> updateNode(
    String nodeId, {
    String? name,
    Map<String, dynamic>? outbound,
  }) async {
    final node = snapshot.nodeById(nodeId);
    if (node == null) return;
    final updated = node.copyWith(name: name, outbound: outbound);
    for (final subscription in snapshot.subscriptions) {
      final index = subscription.nodes.indexWhere((e) => e.id == nodeId);
      if (index >= 0) {
        subscription.nodes[index] = updated;
        break;
      }
    }
    await storage.save(snapshot);
    notifyListeners();
    if (running) await restartCore();
  }

  Future<void> deleteNode(String nodeId) async {
    for (final subscription in snapshot.subscriptions) {
      subscription.nodes.removeWhere((e) => e.id == nodeId);
    }
    if (settings.manualNodeId == nodeId) {
      settings.manualNodeId = null;
      error = '当前节点已删除，请重新选择节点。';
    }
    await storage.save(snapshot);
    notifyListeners();
    if (running) await restartCore();
  }

  Future<String> exportBackup({String? password}) =>
      BackupService.export(snapshot, password: password);

  Future<String> exportLocalBackup({String? password}) async {
    final file = await storage.writeBackup(
      await exportBackup(password: password),
    );
    return file.path;
  }

  Future<void> importBackup(String content, {String? password}) async {
    final restored = await BackupService.import(content, password: password);
    await disconnect();
    snapshot = restored;
    if (Platform.isAndroid) settings.tunEnabled = true;
    await storage.save(snapshot);
    notifyListeners();
  }

  Future<void> resetAll() async {
    await disconnect();
    snapshot = AppSnapshot.empty();
    if (Platform.isAndroid) settings.tunEnabled = true;
    await storage.save(snapshot);
    notifyListeners();
  }

  Future<void> saveSettings() async {
    await storage.save(snapshot);
    appearanceTick.value++;
    notifyListeners();
  }

  Future<void> shutdownForExit() async {
    _cancelExitInfo();
    _subscriptionTimer?.cancel();
    _stopRuleSetUpdates();
    _pollTimer?.cancel();
    _uiTimer?.cancel();
    _pollGeneration++;
    _invalidateConnectionRefresh();
    _cancelNodeTests();
    systemProxy?.disable();
    await runtime.shutdown();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscriptionTimer?.cancel();
    _pollTimer?.cancel();
    _uiTimer?.cancel();
    _pollGeneration++;
    _invalidateConnectionRefresh();
    for (final client in _serviceAddressClients) {
      client.close(force: true);
    }
    _cancelExitInfo();
    _cancelNodeTests();
    _stopRuleSetUpdates();
    liveTick.dispose();
    appearanceTick.dispose();
    _connections.dispose();
    super.dispose();
  }

  void _stopRuleSetUpdates() {
    _ruleSetUpdatesStopped = true;
    _ruleSetStartupTimer?.cancel();
    _ruleSetTimer?.cancel();
  }

  void clearMessages() {
    error = null;
    notice = null;
    notifyListeners();
  }

  void dismissLoadWarning() {
    loadWarning = null;
    notifyListeners();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (running) liveTick.value++;
    });
    _pollTicks = 0;
    _pollFailures = 0;
    _polling = false;
    final generation = ++_pollGeneration;
    _startConnectionPolling();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_poll(generation));
    });
  }

  Future<void> _poll(int generation) async {
    if (_polling || !running || generation != _pollGeneration) return;
    _polling = true;
    try {
      final nextTraffic = await runtime.fetchTraffic();
      if (!running || generation != _pollGeneration) return;
      traffic = nextTraffic;
      _pollFailures = 0;
      _recordTraffic();
      if (_pollTicks % 2 == 0) {
        await _refreshStatus();
        if (!running || generation != _pollGeneration) return;
      }
      _pollTicks++;
    } catch (e) {
      if (!running || generation != _pollGeneration) return;
      _pollFailures++;
      if (_pollFailures >= 3) {
        try {
          await _refreshStatus();
        } catch (_) {
          // Keep the tunnel alive; transport errors are reported by status.
        }
      }
    } finally {
      if (generation == _pollGeneration) _polling = false;
    }
  }

  void _recordTraffic() {
    final now = DateTime.now();
    final previous = _lastTrafficAt;
    if (previous != null) {
      final seconds = now.difference(previous).inMilliseconds / 1000.0;
      if (seconds > 0) {
        final up =
            (traffic.uploaded - _lastUpTotal).clamp(0, 1 << 62) / seconds;
        final down =
            (traffic.downloaded - _lastDownTotal).clamp(0, 1 << 62) / seconds;
        final updated = [
          ...samples,
          TrafficSample(now, up.toDouble(), down.toDouble()),
        ];
        samples = updated.length > 60
            ? updated.sublist(updated.length - 60)
            : updated;
      }
    }
    _lastUpTotal = traffic.uploaded;
    _lastDownTotal = traffic.downloaded;
    _lastTrafficAt = now;
  }

  Future<void> _refreshStatus() async {
    final generation = _pollGeneration;
    final request = ++_statusRequest;
    final status = await runtime.fetchStatus();
    if (!running ||
        generation != _pollGeneration ||
        request < _appliedStatusRequest) {
      return;
    }
    _appliedStatusRequest = request;
    final previousTag = _effectiveTag;
    runtimeStatus = status;
    final group = status.groups[_compiled?.proxyGroupTag];
    _effectiveTag = group?.selected;
    if (!status.running && running) {
      await _handleUnexpectedStop(status.error ?? '内核已停止');
      return;
    }
    if (previousTag != _effectiveTag) {
      unawaited(refreshExitInfo());
      // A node test round already has the measurements it uses to reselect.
      if (!testingNodes) unawaited(_refreshConnectionLatency());
      liveTick.value++;
      notifyListeners();
    }
  }

  Future<void> _handleUnexpectedStop(String message) async {
    if (_unexpectedStop) return;
    _unexpectedStop = true;
    _cancelExitInfo();
    _recordHomeActivity('代理意外停止', failed: true);
    running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;
    _pollGeneration++;
    _invalidateConnectionRefresh();
    _polling = false;
    connectedAt = null;
    error = message;
    systemProxy?.disable();
    // Stop the host runtime as well; on Android the VpnService and its TUN
    // survive an engine crash and would blackhole all device traffic.
    await runtime.shutdown();
    settings.systemProxyEnabled = false;
    await storage.save(snapshot);
    notifyListeners();
  }

  void _setError(String message) {
    error = message;
    notice = null;
    notifyListeners();
  }

  String _friendlyError(Object error) {
    var raw = error.toString();
    if (raw.startsWith('Exception: ')) raw = raw.substring(11);
    if (raw.startsWith('RuntimeException: ')) raw = raw.substring(18);
    if (raw.contains('Failed host lookup')) return '无法解析域名，请检查网络连接';
    if (raw.contains('Connection refused')) return '连接被拒绝';
    if (raw.contains('Connection reset')) return '连接被重置';
    if (raw.contains('TimeoutException') || raw.contains('timed out')) {
      return '请求超时';
    }
    return raw;
  }

  String _newId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final random = Random().nextInt(1 << 31).toRadixString(36);
    return '$now-$random';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

List<int> jsonBytes(Object value) => utf8.encode(jsonEncode(value));
