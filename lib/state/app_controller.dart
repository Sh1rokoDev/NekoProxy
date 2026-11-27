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
import '../services/linux_system_proxy.dart';
import '../services/rule_set_manager.dart';
import '../services/system_proxy.dart';
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
  AppController({
    this._subscriptionDownloadTimeout = const Duration(minutes: 2),
  });

  late final AppPaths paths;
  late final AppStorage storage;
  late final RuntimeClient runtime;
  late final RuleSetManager ruleSets;
  SystemProxy? systemProxy;

  RuleSetStatus? ruleSetStatus;
  bool updatingRuleSets = false;
  String? ruleSetError;

  final ValueNotifier<int> liveTick = ValueNotifier<int>(0);
  final ValueNotifier<int> appearanceTick = ValueNotifier<int>(0);
  final _connections = ValueNotifier<List<RuntimeConnection>>(const []);

  AppSnapshot snapshot = AppSnapshot.empty();
  bool initialized = false;
  bool _busy = false;
  bool get busy => _busy || _savingAdvancedConfig;
  set busy(bool value) => _busy = value;
  bool running = false;
  bool _savingTakeover = false;
  bool _applyingTunTakeover = false;
  bool get applyingTunTakeover => _applyingTunTakeover;
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
  final _nodeTestProgress = ValueNotifier<int>(0);
  int get testCompleted => _nodeTestProgress.value;
  ValueListenable<int> get nodeTestProgress => _nodeTestProgress;
  final _proxyLatencyListeners = <String, _ProxyLatencyNotifier>{};
  int testTotal = 0;
  int _testGeneration = 0;
  final _nodeTestRequests =
      <Object?, ({Set<String> proxyIds, Set<String> wireGuardIds})>{};
  bool _drainingNodeTests = false;
  final Map<String, ServiceCheckResult> serviceChecks = {};
  final Set<String> _servicesChecking = {};
  final Set<HttpClient> _serviceAddressClients = {};
  final Map<String, Object> _subscriptionUpdates = {};
  final _subscriptionClients = <IOClient>{};
  final Duration _subscriptionDownloadTimeout;
  Future<void>? _initializing;
  bool _replacingSnapshot = false;
  Completer<void>? _appearanceSave;
  List<TrafficSample> samples = const [];
  DateTime? connectedAt;
  ExitInfo? exitInfo;
  String? exitInfoError;
  bool checkingExitInfo = false;
  HttpClient? _exitInfoClient;
  HttpClient? _wireGuardEndpointClient;
  String? wireGuardEndpointRegion;
  int _exitInfoGeneration = 0;
  ({String tag, int generation, Object token})? _connectionProbe;
  final _wireGuardLatencies =
      <String, ({String configuration, RuntimeTestResult result})>{};
  RuntimeTestResult? get wireGuardLatency {
    final profile = activeWireGuard;
    return running && profile != null ? wireGuardLatencyFor(profile) : null;
  }

  RuntimeTestResult? wireGuardLatencyFor(WireGuardProfile profile) {
    final measurement = _wireGuardLatencies[profile.id];
    return measurement?.configuration == profile.configuration
        ? measurement?.result
        : null;
  }

  bool _disposed = false;
  final List<HomeActivity> homeActivities = [];
  CompiledConfig? _compiled;
  Map<String, String> _connectionNodeNames = const {};
  Map<String, String> _nodeIdsByTag = const {};
  String? _effectiveTag;
  bool _unexpectedStop = false;
  bool _temporaryTestRuntime = false;
  Future<void>? _temporaryWireGuardStart;
  List<String> _systemDns = const [];

  Timer? _pollTimer;
  Timer? _uiTimer;
  Timer? _connectionsTimer;
  int _connectionViewers = 0;
  Future<void>? _connectionRefresh;
  Object? _connectionRefreshToken;
  final _closingConnectionIds = <String>{};
  Timer? _subscriptionStartupTimer;
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
  bool _closing = false;
  Future<void>? _connecting;
  bool _changingWireGuard = false;
  bool _savingAdvancedConfig = false;
  Future<void>? _configApply;
  int _lastUpTotal = 0;
  int _lastDownTotal = 0;
  DateTime? _lastTrafficAt;

  bool get isAndroid => Platform.isAndroid;
  bool get isLinux => Platform.isLinux;
  bool get supportsSystemProxy =>
      Platform.isWindows || (isLinux && systemProxy != null);

  CompileTarget get _compileTarget => isAndroid
      ? CompileTarget.android
      : isLinux
      ? CompileTarget.linux
      : CompileTarget.windows;
  bool get canChangeTakeover =>
      !_closing && !busy && !_savingTakeover && !_rebuilding;
  bool get tunManagedByConfig =>
      snapshot.useCustomConfig || snapshot.advancedJson.containsKey('inbounds');
  bool get tunTakeoverEnabled =>
      isAndroid ? settings.vpnEnabled : settings.tunEnabled;
  bool get usesTun => running
      ? (_compiled?.hasTunInbound ?? tunTakeoverEnabled)
      : tunTakeoverEnabled;
  bool get hasNodes => snapshot.hasNodes;
  OutboundMode get outboundMode =>
      snapshot.useCustomConfig ? OutboundMode.proxy : snapshot.outboundMode;
  bool get showsRuleMode => outboundMode != OutboundMode.wireGuard;
  bool get chainProxyEnabled => outboundMode == OutboundMode.wireGuardProxy;
  bool get changingWireGuard => _changingWireGuard;
  WireGuardProfile? get activeWireGuard =>
      outboundMode == OutboundMode.proxy ? null : snapshot.wireGuardProfile;

  bool get canConnect =>
      snapshot.useCustomConfig ||
      (outboundMode == OutboundMode.wireGuard
          ? activeWireGuard != null
          : hasNodes && (!chainProxyEnabled || activeWireGuard != null));

  AppSettings get settings => snapshot.settings;

  void _recordHomeActivity(String message, {bool failed = false}) {
    homeActivities.insert(0, HomeActivity(message, failed: failed));
    if (homeActivities.length > 5) homeActivities.removeLast();
  }

  void _cancelExitInfo() {
    _exitInfoGeneration++;
    _exitInfoClient?.close(force: true);
    _exitInfoClient = null;
    _wireGuardEndpointClient?.close(force: true);
    _wireGuardEndpointClient = null;
    wireGuardEndpointRegion = null;
    checkingExitInfo = false;
    exitInfo = null;
    exitInfoError = null;
  }

  Future<void> refreshExitInfo() async {
    if (!running || busy || _disposed) return;
    _cancelExitInfo();
    final generation = _exitInfoGeneration;
    final client = _exitInfoClient = _createManagedHttpClient();
    final endpointRefresh = _refreshWireGuardEndpointRegion(generation);
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
    await endpointRefresh;
  }

  Future<void> _refreshWireGuardEndpointRegion(int generation) async {
    final profile = chainProxyEnabled ? activeWireGuard : null;
    if (profile == null) return;
    final String host;
    try {
      host = profile.parse().firstEndpointHost;
    } on FormatException {
      // Invalid profiles cannot provide an endpoint address.
      return;
    }
    final client = _wireGuardEndpointClient = _createManagedHttpClient();
    try {
      final region = await fetchEndpointRegion(client, host);
      if (running && generation == _exitInfoGeneration) {
        wireGuardEndpointRegion = region;
      }
    } finally {
      if (generation == _exitInfoGeneration) {
        _wireGuardEndpointClient = null;
        notifyListeners();
      }
    }
  }

  bool get refreshingConnectionInfo =>
      checkingExitInfo ||
      _wireGuardEndpointClient != null ||
      _connectionProbe?.generation == _pollGeneration;

  Future<void> refreshConnectionInfo() async {
    if (!running || busy || _disposed || refreshingConnectionInfo) return;
    await Future.wait([refreshExitInfo(), _refreshConnectionLatency()]);
  }

  Future<void> _refreshConnectionLatency() async {
    if (!running || busy || _disposed) return;
    final onlyWireGuard = outboundMode == OutboundMode.wireGuard;
    final profile = onlyWireGuard ? activeWireGuard : null;
    final node = onlyWireGuard ? null : reportedNode;
    if (profile == null && node == null) return;
    if (profile != null && isWireGuardTestRequested(profile.id)) return;
    // Dial the endpoint directly so split-tunnel profiles cannot measure the
    // physical connection when the test URL is outside AllowedIPs.
    final tag = profile != null ? ConfigCompiler.wireGuardTag : _effectiveTag;
    if (tag == null) return;
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
    if (profile != null) {
      final active = activeWireGuard;
      if (outboundMode == OutboundMode.wireGuard &&
          active?.id == profile.id &&
          active?.configuration == profile.configuration) {
        _saveWireGuardLatency(profile, result, requestError);
      }
    } else if (node != null && identical(snapshot.nodeById(node.id), node)) {
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
      await _saveSnapshot(source);
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

  bool isSingleNodeTestRequested(String nodeId) =>
      _nodeTestRequests.containsKey((proxyNodeId: nodeId));

  bool isWireGuardTestRequested(String profileId) => _nodeTestRequests.values
      .any((request) => request.wireGuardIds.contains(profileId));

  bool canTestWireGuardProfile(WireGuardProfile profile) =>
      canQueueNodeTest &&
      !changingWireGuard &&
      (!running || activeWireGuard?.id == profile.id);

  /// Observes intermediate bulk test results for one proxy node.
  VoidCallback watchProxyLatency(String nodeId, VoidCallback listener) {
    final notifier = _proxyLatencyListeners.putIfAbsent(
      nodeId,
      _ProxyLatencyNotifier.new,
    );
    notifier.addListener(listener);
    return () {
      notifier.removeListener(listener);
      if (!notifier.isObserved &&
          identical(_proxyLatencyListeners[nodeId], notifier)) {
        _proxyLatencyListeners.remove(nodeId);
      }
    };
  }

  ProxyNode? get currentNode {
    return reportedNode ?? snapshot.nodeById(settings.manualNodeId);
  }

  /// Returns the URL subscription that owns the current node, or the sole URL
  /// subscription when no node is selected. WireGuard-only mode has no
  /// subscription.
  Subscription? get currentSubscription {
    if (outboundMode == OutboundMode.wireGuard) return null;
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

  RoutingPreview previewRouting() => ConfigCompiler.previewRouting(
    snapshot,
    target: _compileTarget,
    ruleSetPaths: initialized ? ruleSets.pathsByTag : null,
  );

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

  Future<void> initialize({AppPaths? appPaths}) {
    if (initialized || _disposed || _closing) return Future<void>.value();
    return _initializing ??= _initialize(appPaths).whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize(AppPaths? appPaths) async {
    final resolvedPaths = appPaths ?? await AppPaths.resolve();
    final localStorage = AppStorage(resolvedPaths);
    final proxySnapshot = resolvedPaths.proxySnapshotFile;
    final proxy = Platform.isWindows
        ? WindowsSystemProxy(resolvedPaths)
        : isLinux
        ? await LinuxSystemProxy.detect(proxySnapshot)
        : null;
    final loaded = await localStorage.load();
    if (_disposed || _closing) return;
    final rules = RuleSetManager(
      paths: resolvedPaths,
      clientFactory: _createManagedHttpClient,
      // Expert mode can save a copy of the generated paths in its JSON.
      isSnapshotReferenced: (directory) =>
          snapshot.customConfig.contains(directory) ||
          jsonEncode(snapshot.advancedJsonDraft).contains(directory),
    );
    final client = Platform.isAndroid
        ? AndroidRuntimeClient(resolvedPaths)
        : DesktopRuntimeClient(resolvedPaths);
    // Neither task needs results from the other. Both must finish before
    // the home page can compile a config or start a new core.
    final ruleStartup = _initializeRuleSets(rules);
    await _cleanupStaleRuntime(client);
    final (ruleStatus, ruleWarning) = await ruleStartup;
    if (_disposed || _closing) return;
    final restored = await proxy?.restoreIfOwned();
    final restoreWarning =
        restored?.error ??
        (isLinux && proxy == null && await proxySnapshot.exists()
            ? '请在原桌面会话中恢复上一次的系统代理设置'
            : null);
    if (_disposed || _closing) return;

    // Publish the late-final dependencies only when a retry is no longer needed.
    paths = resolvedPaths;
    storage = localStorage;
    systemProxy = proxy;
    ruleSets = rules;
    runtime = client;
    ruleSetStatus = ruleStatus;
    final warnings = [
      loaded.warning,
      ruleWarning,
      restoreWarning,
    ].whereType<String>().join('\n');
    loadWarning = warnings.isEmpty ? null : warnings;
    snapshot = loaded.snapshot;
    initialized = true;
    _subscriptionStartupTimer = Timer(const Duration(seconds: 4), () {
      unawaited(_autoUpdateSubscriptions());
    });
    _subscriptionTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      unawaited(_autoUpdateSubscriptions());
    });
    _ruleSetStartupTimer = Timer(const Duration(seconds: 8), () {
      unawaited(_autoUpdateRuleSets());
    });
    _ruleSetTimer = Timer.periodic(const Duration(hours: 6), (_) {
      unawaited(_autoUpdateRuleSets());
    });
    _publishSettings();
    if (settings.autoConnect && canConnect) {
      unawaited(connect());
    }
  }

  Future<(RuleSetStatus?, String?)> _initializeRuleSets(
    RuleSetManager rules,
  ) async {
    try {
      await rules.initialize();
      return (await rules.readStatus(), null);
    } catch (e) {
      return (null, '分流规则目录初始化失败：$e');
    }
  }

  Future<void> _cleanupStaleRuntime(RuntimeClient client) async {
    try {
      await client.cleanupStale();
    } catch (error) {
      // The previous runtime may already be gone; startup can continue.
      debugPrint(
        'Could not clean up the previous runtime: ${error.runtimeType}',
      );
    }
  }

  Future<void> _autoUpdateSubscriptions() async {
    final now = DateTime.now();
    for (final subscription in List<Subscription>.of(snapshot.subscriptions)) {
      if (_disposed || _closing || _replacingSnapshot) return;
      if (!subscription.isAutoUpdateDue(now)) continue;
      try {
        await updateSubscription(subscription.id, silent: true);
      } catch (_) {}
    }
  }

  Future<void> _autoUpdateRuleSets() async {
    if (!settings.ruleSetAutoUpdate) return;
    if (ruleSetStatus != null &&
        !await ruleSets.isUpdateDue(const Duration(hours: 24))) {
      return;
    }
    await updateRuleSets(automatic: true);
  }

  Future<void> updateRuleSets({bool automatic = false}) async {
    if (_ruleSetUpdatesStopped || updatingRuleSets || _savingAdvancedConfig) {
      return;
    }
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
    if (_ruleSetUpdatesStopped || updatingRuleSets || _savingAdvancedConfig) {
      return;
    }
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

  CompiledConfig compile([AppSnapshot? candidate]) {
    return ConfigCompiler.compile(
      candidate ?? snapshot,
      target: _compileTarget,
      cachePath: '${paths.runtime.path}${Platform.pathSeparator}cache.db',
      logPath: paths.logFile.path,
      systemDnsServers: _systemDns,
      ruleSetPaths: ruleSets.pathsByTag,
    );
  }

  Future<void> setChainProxyEnabled(bool enabled) => _changeWireGuard((draft) {
    if (enabled && (draft.wireGuardProfile == null || !draft.hasNodes)) {
      throw const ConfigCompileException('请先在节点页选择 WireGuard 和 sing-box 节点。');
    }
    if (draft.useCustomConfig) {
      throw const ConfigCompileException('当前出站由完整自定义配置接管。');
    }
    draft.chainProxyEnabled = enabled;
  }, allowMissing: !enabled);

  Future<void> selectWireGuard(String id) => _changeWireGuard((draft) {
    if (draft.useCustomConfig) {
      throw const ConfigCompileException('当前出站由完整自定义配置接管。');
    }
    draft.wireGuardProfileId = id;
    if (draft.wireGuardProfile == null) {
      throw const ConfigCompileException('WireGuard 节点不存在。');
    }
    if (!draft.chainProxyEnabled) {
      draft.standaloneOutbound = StandaloneOutbound.wireGuard;
    }
  });

  Future<void> saveWireGuardGroup(String name, {String? id}) =>
      _changeWireGuard((draft) {
        final group = WireGuardGroup(id: id ?? _newId(), name: name.trim());
        if (group.name.isEmpty) {
          throw const ConfigCompileException('请输入分组名称。');
        }
        final index = draft.wireGuardGroups.indexWhere(
          (item) => item.id == group.id,
        );
        if (index < 0) {
          draft.wireGuardGroups.add(group);
        } else {
          draft.wireGuardGroups[index] = group;
        }
      });

  Future<void> saveWireGuardProfile(WireGuardProfile profile) =>
      _changeWireGuard((draft) {
        profile.parse();
        if (!draft.wireGuardGroups.any(
          (group) => group.id == profile.groupId,
        )) {
          throw const ConfigCompileException('WireGuard 分组不存在。');
        }
        final index = draft.wireGuardProfiles.indexWhere(
          (item) => item.id == profile.id,
        );
        if (index < 0) {
          draft.wireGuardProfiles.add(profile);
        } else {
          draft.wireGuardProfiles[index] = profile;
        }
      });

  Future<void> deleteWireGuardGroup(String id) => _changeWireGuard((draft) {
    draft.wireGuardGroups.removeWhere((group) => group.id == id);
    draft.wireGuardProfiles.removeWhere((profile) => profile.groupId == id);
    if (draft.wireGuardProfile == null) draft.wireGuardProfileId = null;
  }, removing: true);

  Future<void> deleteWireGuardProfile(String id) => _changeWireGuard((draft) {
    draft.wireGuardProfiles.removeWhere((profile) => profile.id == id);
    if (draft.wireGuardProfileId == id) draft.wireGuardProfileId = null;
  }, removing: true);

  Future<void> _changeWireGuard(
    void Function(AppSnapshot) edit, {
    bool removing = false,
    bool allowMissing = false,
  }) async {
    if (_appearanceSave case final save?) await save.future;
    if (busy || _rebuilding || _changingWireGuard) {
      throw const ConfigCompileException('正在切换连接，请稍后重试。');
    }
    _changingWireGuard = true;
    notifyListeners();
    try {
      final draft = AppSnapshot.fromJson(snapshot.toJson());
      edit(draft);
      final nextMode = draft.useCustomConfig
          ? OutboundMode.proxy
          : draft.outboundMode;
      final nextProfile = nextMode == OutboundMode.proxy
          ? null
          : draft.wireGuardProfile;
      final previousProfile = activeWireGuard;
      final changed =
          nextMode != outboundMode ||
          nextProfile?.id != previousProfile?.id ||
          nextProfile?.configuration != previousProfile?.configuration;
      final selectionLost =
          (removing || allowMissing) &&
          changed &&
          nextProfile == null &&
          nextMode != OutboundMode.proxy;
      if (changed &&
          !selectionLost &&
          (nextMode != OutboundMode.proxy || draft.hasNodes)) {
        compile(draft);
      }
      await storage.save(draft);
      if (_disposed) return;
      snapshot
        ..chainProxyEnabled = draft.chainProxyEnabled
        ..standaloneOutbound = draft.standaloneOutbound
        ..wireGuardProfileId = draft.wireGuardProfileId
        ..wireGuardGroups = draft.wireGuardGroups
        ..wireGuardProfiles = draft.wireGuardProfiles;
      final profilesById = {
        for (final profile in draft.wireGuardProfiles) profile.id: profile,
      };
      _wireGuardLatencies.removeWhere(
        (id, measurement) =>
            profilesById[id]?.configuration != measurement.configuration,
      );
      settings
        ..manualNodeId = draft.settings.manualNodeId
        ..selectionMode = draft.settings.selectionMode;
      notifyListeners();
      if (selectionLost) {
        if (running) await disconnect(silent: true);
        _setError(
          removing ? '当前 WireGuard 节点已删除，请在节点页重新选择。' : '请在节点页选择 WireGuard 节点。',
        );
      } else if (changed && running) {
        await restartCore();
      }
    } finally {
      _changingWireGuard = false;
      if (!_disposed) notifyListeners();
    }
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
    if (!_rebuilding && !_savingAdvancedConfig) await _connect();
  }

  Future<void> _connect() async {
    if (_closing || _connecting != null) return;
    final connecting = _connectOnce();
    _connecting = connecting;
    try {
      await connecting;
    } finally {
      _connecting = null;
    }
  }

  Future<void> _connectOnce() async {
    if (busy || running || (_changingWireGuard && !_rebuilding)) return;
    if (!canConnect) {
      _setError(
        outboundMode != OutboundMode.proxy && activeWireGuard == null
            ? '请在节点页选择 WireGuard 节点。'
            : '还没有可用节点，请先导入订阅或节点。',
      );
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
      final status = await _startConfiguredCore(compiled, settings);
      _publishRunningCore(compiled, status);
      try {
        await _refreshStatus();
      } catch (_) {
        // Status is best effort; the poll loop retries and reports a stop.
      }
    } catch (e) {
      running = false;
      _cancelExitInfo();
      if (!_applyingTunTakeover) _recordHomeActivity('代理连接失败', failed: true);
      _pollTimer?.cancel();
      _uiTimer?.cancel();
      _setError(_friendlyError(e));
      await _restoreSystemProxy();
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
      await _saveSnapshot(snapshot);
    }
  }

  Future<RuntimeStatus> _startConfiguredCore(
    CompiledConfig compiled,
    AppSettings configSettings, {
    bool strict = false,
  }) async {
    if (isAndroid &&
        compiled.hasTunInbound &&
        configSettings.perAppMode == PerAppMode.allow &&
        configSettings.perAppPackages.isEmpty) {
      throw const RuntimeException('应用过滤已选择“代理所选”，但还没有勾选任何应用。');
    }
    final client = runtime;
    if (client is AndroidRuntimeClient) {
      await client.setCpuWakeLockEnabled(configSettings.cpuWakeLockEnabled);
    }
    final status = await client.start(
      config: compiled.encoded,
      mode: compiled.hasTunInbound ? 'tun' : 'normal',
      perAppMode: configSettings.perAppMode.name,
      perAppPackages: configSettings.perAppPackages,
    );
    if (!status.running) {
      throw RuntimeException(status.error ?? '核心尚未就绪');
    }
    final tag = compiled.nodeTags[configSettings.manualNodeId];
    if (configSettings.selectionMode == SelectionMode.manual && tag != null) {
      try {
        await client.select(tag);
      } catch (cause) {
        if (strict) rethrow;
        debugPrint('Could not apply the selected node: ${cause.runtimeType}');
      }
    }
    final proxy = systemProxy;
    if (!_closing && configSettings.systemProxyEnabled && proxy != null) {
      final result = await _applySystemProxy(proxy, compiled);
      if (!result.ok) {
        final message = result.error ?? '设置系统代理失败';
        if (strict) throw RuntimeException(message);
        error = message;
      }
    }
    return status;
  }

  void _publishRunningCore(CompiledConfig compiled, RuntimeStatus status) {
    _compiled = compiled;
    runtimeStatus = status;
    _updateConnectionNodeNames(compiled);
    _nodeIdsByTag = {
      for (final entry in compiled.nodeTags.entries) entry.value: entry.key,
    };
    _effectiveTag = null;
    if (compiled.warnings.isNotEmpty) notice = compiled.warnings.first;
    running = true;
    connectedAt = DateTime.now();
    _lastUpTotal = 0;
    _lastDownTotal = 0;
    _lastTrafficAt = null;
    samples = const [];
    if (!_applyingTunTakeover) _recordHomeActivity('代理已连接');
    _startPolling();
  }

  void _updateConnectionNodeNames(CompiledConfig compiled) {
    final names = {for (final node in snapshot.allNodes) node.id: node.name};
    _connectionNodeNames = {
      for (final entry in compiled.nodeTags.entries)
        if (names[entry.key] case final name? when name.isNotEmpty)
          entry.value: name,
    };
  }

  Future<void> disconnect({bool silent = false}) async {
    await _waitForAdvancedConfig();
    await _disconnect(silent: silent);
  }

  Future<void> _disconnect({required bool silent, bool strict = false}) async {
    _cancelExitInfo();
    final wasRunning = running;
    busy = true;
    if (!silent) notifyListeners();
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
      try {
        await runtime.shutdown();
      } finally {
        _connectionNodeNames = const {};
        _nodeIdsByTag = const {};
        busy = false;
        notifyListeners();
      }
      return;
    }
    try {
      await _restoreSystemProxy(strict: strict);
      await runtime.shutdown();
    } catch (e) {
      if (strict) rethrow;
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
      if (wasRunning && !_applyingTunTakeover) _recordHomeActivity('代理已断开');
      busy = false;
      notifyListeners();
    }
  }

  Future<void> toggleConnection() async {
    if (busy || _rebuilding) return;
    if (running) {
      await disconnect();
    } else {
      await connect();
    }
  }

  Future<void> restartCore() async {
    if (_rebuilding || busy) return;
    _rebuilding = true;
    try {
      final wasRunning = running;
      await disconnect(silent: true);
      if (wasRunning) await _connect();
    } finally {
      _rebuilding = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<List<InstalledApp>> installedApps() => runtime.installedApps();

  Future<Uint8List?> installedAppIcon(String packageName, int size) =>
      runtime.installedAppIcon(packageName, size);

  Future<void> updatePerApp(PerAppMode mode, List<String> packages) async {
    final current = settings;
    final previousMode = current.perAppMode;
    final previousPackages = current.perAppPackages;
    current.perAppMode = mode;
    current.perAppPackages = List.of(packages);
    try {
      await _saveSnapshot(snapshot);
    } catch (_) {
      current.perAppMode = previousMode;
      current.perAppPackages = previousPackages;
      rethrow;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> setSplitMode(SplitMode mode) async {
    final previous = settings.splitMode;
    if (!canChangeSplitMode || previous == mode) return;
    _changingSplitMode = true;
    settings.splitMode = mode;
    notifyListeners();
    try {
      try {
        await _saveSnapshot(snapshot);
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
    if (_changingWireGuard || _savingAdvancedConfig) return;
    if (outboundMode == OutboundMode.wireGuard && mode == SelectionMode.auto) {
      try {
        await _changeWireGuard((draft) {
          if (!draft.hasNodes) {
            throw const ConfigCompileException('请先添加 sing-box 节点。');
          }
          draft.standaloneOutbound = StandaloneOutbound.singBox;
          draft.settings.selectionMode = mode;
        });
      } on Exception catch (error) {
        _setError(_friendlyError(error));
      }
      return;
    }
    if (settings.selectionMode == mode) return;
    settings.selectionMode = mode;
    await _saveSnapshot(snapshot);
    notifyListeners();
    if (running) await restartCore();
  }

  Future<void> selectNode(String nodeId) async {
    if (_changingWireGuard || _savingAdvancedConfig) return;
    final node = snapshot.nodeById(nodeId);
    if (node == null) return;
    if (outboundMode == OutboundMode.wireGuard) {
      try {
        await _changeWireGuard((draft) {
          draft.standaloneOutbound = StandaloneOutbound.singBox;
          draft.settings.manualNodeId = nodeId;
          draft.settings.selectionMode = SelectionMode.manual;
        });
      } on Exception catch (error) {
        _setError(_friendlyError(error));
      }
      return;
    }
    final wasAuto = settings.selectionMode == SelectionMode.auto;
    settings.manualNodeId = nodeId;
    settings.selectionMode = SelectionMode.manual;
    await _saveSnapshot(snapshot);
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
    await _saveSnapshot(snapshot);
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
    await _saveSnapshot(snapshot);
    notifyListeners();
    if (running && settings.selectionMode == SelectionMode.auto) {
      await restartCore();
    }
  }

  Future<void> toggleFavorite(String nodeId) async {
    final node = snapshot.nodeById(nodeId);
    if (node == null) return;
    node.favorite = !node.favorite;
    await _saveSnapshot(snapshot);
    notifyListeners();
  }

  int _systemProxyPort(CompiledConfig config) {
    final inbounds = config.json['inbounds'];
    final mixed = inbounds is List
        ? inbounds.whereType<Map>().where(
            (inbound) =>
                inbound['type'] == 'mixed' &&
                const {'127.0.0.1', '0.0.0.0'}.contains(inbound['listen']),
          )
        : const <Map>[];
    if (mixed.length != 1) {
      throw const ConfigCompileException('系统代理需要一个监听 IPv4 回环的混合入站，请按实际入站手动配置。');
    }
    final inbound = mixed.single;
    final users = inbound['users'];
    if (users != null && (users is! List || users.isNotEmpty)) {
      throw const ConfigCompileException('当前混合入站需要认证，请在应用中手动配置代理。');
    }
    final listenPort = inbound['listen_port'];
    if (listenPort is! int || listenPort < 1 || listenPort > 65535) {
      throw const ConfigCompileException('混合入站端口无效');
    }
    return listenPort;
  }

  Future<ProxyApplyResult> _enableSystemProxy(SystemProxy proxy) async {
    final config = _compiled;
    if (config == null) {
      return const ProxyApplyResult(ok: false, error: '核心尚未应用配置');
    }
    return _applySystemProxy(proxy, config);
  }

  Future<ProxyApplyResult> _applySystemProxy(
    SystemProxy proxy,
    CompiledConfig config,
  ) async {
    try {
      return await proxy.enable(_systemProxyPort(config));
    } on ConfigCompileException catch (error) {
      return ProxyApplyResult(ok: false, error: error.message);
    }
  }

  Future<void> _restoreSystemProxy({bool strict = false}) async {
    final restored = await systemProxy?.disable();
    if (strict && restored?.ok == false) {
      throw RuntimeException(restored?.error ?? '恢复系统代理失败');
    }
    if (isLinux && restored?.error != null) {
      error = [error, restored?.error].whereType<String>().join('\n');
    }
  }

  Future<void> setSystemProxy(bool enabled) async {
    if (!supportsSystemProxy ||
        !canChangeTakeover ||
        settings.systemProxyEnabled == enabled) {
      return;
    }
    _savingTakeover = true;
    final current = settings;
    current.systemProxyEnabled = enabled;
    try {
      await _saveSnapshot(snapshot);
      final proxy = systemProxy;
      if (!_closing && running && !busy && proxy != null) {
        final result = enabled
            ? await _enableSystemProxy(proxy)
            : await proxy.disable();
        if (!result.ok) {
          current.systemProxyEnabled = !enabled;
          await _saveSnapshot(snapshot);
          _setError(result.error ?? '切换系统代理失败');
        }
      }
    } catch (error) {
      current.systemProxyEnabled = !enabled;
      _setError('系统代理设置保存失败：${_friendlyError(error)}');
    } finally {
      _savingTakeover = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> setTun(bool enabled) async {
    if (!canChangeTakeover ||
        tunManagedByConfig ||
        tunTakeoverEnabled == enabled) {
      return;
    }
    if (running &&
        enabled &&
        isAndroid &&
        settings.perAppMode == PerAppMode.allow &&
        settings.perAppPackages.isEmpty) {
      _setError('应用过滤已选择“代理所选”，请先选择应用再开启 VPN。');
      return;
    }
    final current = settings;
    void update(bool value) {
      if (isAndroid) {
        current.vpnEnabled = value;
      } else {
        current.tunEnabled = value;
      }
    }

    _savingTakeover = true;
    update(enabled);
    try {
      try {
        await _saveSnapshot(snapshot);
      } catch (error) {
        update(!enabled);
        _setError('接管设置保存失败：${_friendlyError(error)}');
        return;
      }
      if (_disposed || busy || !running) return;
      final type = isAndroid ? 'VPN' : 'TUN';
      _applyingTunTakeover = true;
      notifyListeners();
      await restartCore();
      if (running) {
        _recordHomeActivity('$type 已${enabled ? '开启' : '关闭'}');
      } else {
        final failure = error ?? '内核启动失败';
        update(!enabled);
        await connect();
        final result = running ? '已恢复原接管方式' : '原连接恢复失败';
        final message = '$type 切换失败，$result：$failure';
        _recordHomeActivity(message, failed: true);
        _setError(message);
      }
    } finally {
      _applyingTunTakeover = false;
      _savingTakeover = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> updateDns(DnsSettings Function(DnsSettings) change) async {
    final value = settings.dnsOrDefault;
    change(value);
    settings.dns = value;
    await _saveSnapshot(snapshot);
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
    await _saveSnapshot(snapshot);
    notifyListeners();
    if (restart && running) await restartCore();
  }

  Future<void> saveRules(List<RoutingRule> rules) async {
    snapshot.rules = rules;
    await _saveSnapshot(snapshot);
    notifyListeners();
    if (running) await restartCore();
  }

  Future<void> saveAdvancedConfig(AdvancedConfigMode mode, String text) async {
    if (_appearanceSave case final save?) await save.future;
    if (_closing ||
        busy ||
        _replacingSnapshot ||
        _connecting != null ||
        _rebuilding ||
        _savingTakeover ||
        _changingSplitMode ||
        _changingWireGuard ||
        updatingRuleSets) {
      throw const ConfigCompileException('正在应用配置，请稍后重试。');
    }
    Map<String, dynamic> json = const {};
    if (mode != AdvancedConfigMode.off) {
      if (mode == AdvancedConfigMode.override && text.trim().isEmpty) {
        throw const FormatException('请先填写完整配置');
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('根节点必须是 JSON 对象');
      }
      if (CompiledConfig.containsRedactedValue(decoded)) {
        throw const FormatException('请替换预览中的脱敏占位符后再使用此配置');
      }
      final violations = ConfigPolicy.validate(decoded);
      if (violations.isNotEmpty) {
        throw FormatException(
          '包含被禁止的设置：${violations.map((e) => e.message).join('；')}',
        );
      }
      if (mode == AdvancedConfigMode.override &&
          decoded['outbounds'] is! List) {
        throw const FormatException('完整配置必须包含 outbounds 数组');
      }
      json = decoded;
    }
    final draft = AppSnapshot.fromJson(snapshot.toJson());
    final useExtension = mode == AdvancedConfigMode.extension;
    final useOverride = mode == AdvancedConfigMode.override;
    draft
      ..inactiveAdvancedJson = useExtension ? null : snapshot.advancedJsonDraft
      ..advancedJson = useExtension ? json : const {}
      ..customConfig = useOverride ? text : snapshot.customConfig
      ..useCustomConfig = useOverride;
    _savingAdvancedConfig = true;
    final task = _applyAdvancedConfig(draft);
    _configApply = task;
    notifyListeners();
    try {
      await task;
    } finally {
      _configApply = null;
      _savingAdvancedConfig = false;
      if (!_closing && !_disposed) {
        notifyListeners();
        if (running && !checkingExitInfo && exitInfo == null) {
          unawaited(refreshExitInfo());
          unawaited(_refreshConnectionLatency());
        }
      }
    }
  }

  Future<void> _applyAdvancedConfig(AppSnapshot draft) async {
    final original = _compiled;
    final wasRunning = running;
    CompiledConfig? candidate;
    if ((initialized || wasRunning) &&
        (wasRunning ||
            draft.useCustomConfig ||
            draft.hasNodes ||
            draft.wireGuardProfile != null)) {
      if (wasRunning) await _refreshSystemDns();
      candidate = compile(draft);
      final validator = runtime;
      if (validator is RuntimeConfigValidator) {
        await validator.validateConfig(candidate.encoded);
      }
      if (wasRunning &&
          draft.settings.systemProxyEnabled &&
          systemProxy != null) {
        _systemProxyPort(candidate);
      }
      await ruleSets.prepareLocalFiles(candidate.localRuleSetPaths);
    }

    void checkActive() {
      if (_closing || _disposed) {
        throw const ConfigCompileException('已取消应用配置');
      }
    }

    checkActive();
    RuntimeStatus? status;
    var switched = false;
    try {
      if (wasRunning && candidate != null) {
        switched = true;
        await _disconnect(silent: true, strict: true);
        checkActive();
        status = await _startConfiguredCore(
          candidate,
          draft.settings,
          strict: true,
        );
      }
      checkActive();
      final updated = AppSnapshot.fromJson(snapshot.toJson())
        ..inactiveAdvancedJson = draft.inactiveAdvancedJson
        ..advancedJson = draft.advancedJson
        ..customConfig = draft.customConfig
        ..useCustomConfig = draft.useCustomConfig;
      await storage.save(updated);
    } catch (cause) {
      if (!switched || _closing || _disposed) rethrow;
      try {
        await _restoreSystemProxy(strict: true);
        await runtime.shutdown();
        if (original == null) throw const RuntimeException('缺少原运行配置');
        final restored = await _startConfiguredCore(
          original,
          settings,
          strict: true,
        );
        _publishRunningCore(original, restored);
      } catch (rollback) {
        try {
          await _restoreSystemProxy();
          await runtime.shutdown();
        } catch (cleanup) {
          debugPrint(
            'Could not clean up a failed config rollback: ${cleanup.runtimeType}',
          );
        }
        throw ConfigCompileException(
          '应用配置失败：${_friendlyError(cause)}；原连接恢复失败：${_friendlyError(rollback)}',
        );
      }
      throw ConfigCompileException('应用配置失败，已恢复原连接：${_friendlyError(cause)}');
    }
    snapshot
      ..inactiveAdvancedJson = draft.inactiveAdvancedJson
      ..advancedJson = draft.advancedJson
      ..customConfig = draft.customConfig
      ..useCustomConfig = draft.useCustomConfig;
    if (!_closing && !_disposed && status != null && candidate != null) {
      error = null;
      notice = null;
      _unexpectedStop = false;
      ruleSets.pinActiveSnapshotForCore();
      _publishRunningCore(candidate, status);
    }
  }

  Future<void> _stopTemporaryTestRuntime() async {
    if (!_temporaryTestRuntime) return;
    _temporaryTestRuntime = false;
    final starting = _temporaryWireGuardStart;
    if (starting != null) {
      // The worker may still be launching when a shutdown cancels this test.
      await starting;
    }
    try {
      await runtime.stopTest();
    } catch (_) {}
  }

  void queueNodeTest(
    Iterable<ProxyNode> nodes, {
    String? groupId,
    Iterable<WireGuardProfile> wireGuardProfiles = const [],
  }) => _queueNodeTest(groupId, nodes, wireGuardProfiles);

  void queueSingleNodeTest(ProxyNode node) =>
      _queueNodeTest((proxyNodeId: node.id), [node], const []);

  void queueWireGuardTest(
    Iterable<WireGuardProfile> profiles, {
    String? groupId,
  }) => _queueNodeTest(
    (groupId, groupId == null ? profiles.firstOrNull?.id : null),
    const [],
    profiles,
  );

  void _queueNodeTest(
    Object? key,
    Iterable<ProxyNode> nodes,
    Iterable<WireGuardProfile> profiles,
  ) {
    if (_disposed || !canQueueNodeTest || _nodeTestRequests.containsKey(key)) {
      return;
    }
    final proxyIds = {for (final node in nodes) node.id};
    final wireGuardIds = {
      for (final profile in profiles)
        if (canTestWireGuardProfile(profile)) profile.id,
    };
    if (proxyIds.isEmpty && wireGuardIds.isEmpty) return;
    _nodeTestRequests[key] = (proxyIds: proxyIds, wireGuardIds: wireGuardIds);
    notifyListeners();
    if (!_drainingNodeTests) {
      unawaited(_drainNodeTests());
    }
  }

  Future<void> _drainNodeTests() async {
    _drainingNodeTests = true;
    try {
      while (_nodeTestRequests.isNotEmpty) {
        final MapEntry(:key, value: request) = _nodeTestRequests.entries.first;
        try {
          // Use the current configuration for nodes still present when their turn starts.
          final profiles = snapshot.wireGuardProfiles
              .where(
                (profile) =>
                    request.wireGuardIds.contains(profile.id) &&
                    canTestWireGuardProfile(profile),
              )
              .toList();
          var completed = 0;
          if (request.proxyIds.isNotEmpty) {
            await testNodes(
              nodes: snapshot.allNodes.where(
                (node) => request.proxyIds.contains(node.id),
              ),
              additionalTests: profiles.length,
            );
            completed = testCompleted;
          }
          if (profiles.isNotEmpty &&
              identical(_nodeTestRequests[key], request)) {
            await _testWireGuardProfiles(
              profiles,
              pendingIds: request.wireGuardIds,
              completed: completed,
            );
          }
        } catch (error) {
          if (identical(_nodeTestRequests[key], request)) {
            _setError(_friendlyError(error));
          }
        } finally {
          if (identical(_nodeTestRequests[key], request)) {
            _nodeTestRequests.remove(key);
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

  Future<void> testNodes({
    Iterable<ProxyNode>? nodes,
    int additionalTests = 0,
  }) async {
    if (testingNodes || busy) return;
    if (outboundMode == OutboundMode.wireGuard) {
      _setError('仅 WireGuard 模式不使用代理节点。');
      return;
    }
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
          target: _compileTarget,
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
    testTotal = queue.length + additionalTests;
    _nodeTestProgress.value = 0;
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
      _nodeTestProgress.value++;
      _proxyLatencyListeners[node.id]?.publish();
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

  Future<void> _testWireGuardProfiles(
    List<WireGuardProfile> profiles, {
    required Set<String> pendingIds,
    required int completed,
  }) async {
    if (busy || testingNodes || _disposed) return;
    final run = ++_testGeneration;
    final temporary = !running;
    final url = settings.advancedOrDefault.urlTestUrl;
    testingNodes = true;
    testTotal = completed + profiles.length;
    _nodeTestProgress.value = completed;
    notifyListeners();
    try {
      if (temporary) await _refreshSystemDns();
      for (final profile in profiles) {
        if (run != _testGeneration) break;
        RuntimeTestResult? result;
        String? requestError;
        try {
          if (temporary) {
            final config = ConfigCompiler.compile(
              AppSnapshot(
                settings: AppSettings(),
                subscriptions: [],
                outboundMode: OutboundMode.wireGuard,
                wireGuardProfileId: profile.id,
                wireGuardProfiles: [profile],
              ),
              target: _compileTarget,
              cachePath: paths.runtime.path,
              testOnly: true,
              systemDnsServers: _systemDns,
            );
            final started = Completer<void>();
            _temporaryWireGuardStart = started.future;
            _temporaryTestRuntime = true;
            busy = true;
            notifyListeners();
            try {
              await runtime.startTest(config: config.encoded);
            } finally {
              started.complete();
              _temporaryWireGuardStart = null;
              if (run == _testGeneration) {
                busy = false;
                notifyListeners();
              }
            }
          } else if (activeWireGuard?.id != profile.id ||
              activeWireGuard?.configuration != profile.configuration) {
            continue;
          } else if (_connectionProbe?.tag == ConfigCompiler.wireGuardTag) {
            // A manual retest takes precedence over an older homepage probe.
            _connectionProbe = null;
          }
          if (run != _testGeneration) break;
          const tag = ConfigCompiler.wireGuardTag;
          result = (await runtime.test([tag], url))[tag];
        } catch (error) {
          requestError = _friendlyError(error);
        } finally {
          if (temporary && run == _testGeneration && _temporaryTestRuntime) {
            busy = true;
            await _stopTemporaryTestRuntime();
            if (run == _testGeneration) busy = false;
          }
        }
        if (run != _testGeneration) break;
        final current = snapshot.wireGuardProfiles
            .where((candidate) => candidate.id == profile.id)
            .firstOrNull;
        if (current?.configuration == profile.configuration) {
          _saveWireGuardLatency(profile, result, requestError);
        }
        pendingIds.remove(profile.id);
        _nodeTestProgress.value++;
        notifyListeners();
      }
    } finally {
      if (run == _testGeneration) {
        testingNodes = false;
        notifyListeners();
      }
    }
  }

  void _saveWireGuardLatency(
    WireGuardProfile profile,
    RuntimeTestResult? result,
    String? requestError,
  ) {
    _wireGuardLatencies[profile.id] = (
      configuration: profile.configuration,
      result: switch (result?.delay) {
        final int delay => RuntimeTestResult(delay: delay),
        null => RuntimeTestResult(error: _probeError(result, requestError)),
      },
    );
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
      _latencyErrors[nodeId] = _probeError(result, requestError);
    }
  }

  String _probeError(RuntimeTestResult? result, String? requestError) {
    final message = result?.error?.trim();
    return requestError ??
        (message == null || message.isEmpty ? '测速失败' : message);
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
      usesTun &&
      (!isAndroid || settings.perAppMode != PerAppMode.allow);

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
    final source = snapshot;
    if (_replacingSnapshot) throw const ParseException('订阅导入已取消');
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
    if (_disposed ||
        _closing ||
        _replacingSnapshot ||
        !identical(snapshot, source)) {
      throw const ParseException('订阅导入已取消');
    }
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
    await _saveSnapshot(snapshot);
    if (!_disposed && identical(snapshot, source)) notifyListeners();
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
    await _saveSnapshot(snapshot);
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
    await _saveSnapshot(snapshot);
    notifyListeners();
    return group;
  }

  /// Reorders visible node groups while preserving the slots of hidden groups.
  Future<void> reorderNodeGroups(List<String> orderedKeys) async {
    if (_changingWireGuard) return;
    final source = snapshot;
    final previous = source.nodeGroupOrder;
    final current = source.orderedNodeGroupKeys;
    final visible = orderedKeys.toSet();
    if (visible.length != orderedKeys.length ||
        !current.toSet().containsAll(visible)) {
      return;
    }
    var nextIndex = 0;
    final reordered = [
      for (final key in current)
        if (visible.contains(key)) orderedKeys[nextIndex++] else key,
    ];
    if (listEquals(current, reordered)) return;
    source.nodeGroupOrder = reordered;
    try {
      await _saveSnapshot(source);
    } catch (exception) {
      if (!identical(snapshot, source)) return;
      if (identical(source.nodeGroupOrder, reordered)) {
        source.nodeGroupOrder = previous;
      }
      _setError('分组顺序保存失败：${_friendlyError(exception)}');
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
    await _saveSnapshot(snapshot);
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
    await _saveSnapshot(snapshot);
    notifyListeners();
  }

  Future<void> updateSubscription(String id, {bool silent = false}) async {
    if (_disposed || _closing || _replacingSnapshot || _savingAdvancedConfig) {
      return;
    }
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
          _closing ||
          _replacingSnapshot ||
          _savingAdvancedConfig ||
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
      final selectedBefore = settings.manualNodeId;
      final hadSelection = snapshot.nodeById(selectedBefore) != null;
      current
        ..nodes = _mergeSubscriptionNodes(current.nodes, parsed.nodes)
        ..lastUpdated = DateTime.now()
        ..lastError = null
        ..uploadBytes = parsed.uploadBytes
        ..downloadBytes = parsed.downloadBytes
        ..totalBytes = parsed.totalBytes
        ..expireAt = parsed.expireAt;
      final selectionMissing =
          selectedBefore != null && snapshot.nodeById(selectedBefore) == null;
      if (selectionMissing) settings.manualNodeId = null;
      await _saveSnapshot(snapshot);
      if (currentSubscription() == null) return;
      final active = running ? _compiled : null;
      if (active != null) _updateConnectionNodeNames(active);
      _recordHomeActivity('订阅更新完成，共 ${parsed.nodes.length} 个节点');
      notifyListeners();

      if (currentSubscription() == null) return;
      if (_lostSubscriptionSelection(
        active,
        hadSelection && selectionMissing,
      )) {
        if (running) await disconnect(silent: true);
        if (currentSubscription() == null) return;
        _setError('原选中节点已从订阅移除，请重新选择节点。');
      } else if (active != null && running && identical(_compiled, active)) {
        await _applySubscriptionConfig(active);
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
      await _saveSnapshot(snapshot);
      if (currentSubscription() == null) return;
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

  List<ProxyNode> _mergeSubscriptionNodes(
    List<ProxyNode> current,
    List<ProxyNode> incoming,
  ) {
    final unmatched = {
      for (final node in current)
        ProfileParser.fingerprintOf(node.outbound): node,
    };
    final matched = {
      for (final node in incoming)
        node.id: ?unmatched.remove(ProfileParser.fingerprintOf(node.outbound)),
    };

    if (unmatched.isNotEmpty && matched.length < incoming.length) {
      // Keep existing IDs when just the ignored upstream references change.
      // Reserve exact matches first when multiple nodes compile identically.
      String effectiveFingerprint(ProxyNode node) =>
          ProfileParser.fingerprintOf(
            ConfigCompiler.subscriptionOutbound(node),
          );
      final byEffectiveOutbound = <String, Queue<ProxyNode>>{};
      for (final node in unmatched.values) {
        byEffectiveOutbound
            .putIfAbsent(effectiveFingerprint(node), Queue.new)
            .addLast(node);
      }
      for (final node in incoming) {
        if (matched.containsKey(node.id)) continue;
        final candidates = byEffectiveOutbound[effectiveFingerprint(node)];
        if (candidates != null && candidates.isNotEmpty) {
          matched[node.id] = candidates.removeFirst();
        }
      }
    }

    return [
      for (final node in incoming)
        if (matched[node.id] case final previous?)
          previous.copyWith(
            name: node.name,
            tag: node.tag,
            outbound: node.outbound,
          )
        else
          node,
    ];
  }

  bool _lostSubscriptionSelection(
    CompiledConfig? active,
    bool selectionRemoved,
  ) {
    if (settings.selectionMode != SelectionMode.manual ||
        settings.manualNodeId != null) {
      return false;
    }
    if (active == null) {
      return !running &&
          selectionRemoved &&
          !snapshot.useCustomConfig &&
          outboundMode != OutboundMode.wireGuard &&
          !snapshot.advancedJson.containsKey('outbounds');
    }
    if (!active.hasGeneratedProxyOutbounds ||
        active.proxyGroupTag != ConfigCompiler.proxyTag) {
      return false;
    }
    final selectedId =
        _nodeIdsByTag[_effectiveTag ?? active.generatedManualDefault];
    return selectedId != null && snapshot.nodeById(selectedId) == null;
  }

  Future<void> _applySubscriptionConfig(CompiledConfig active) async {
    if (active.nodeTags.isEmpty) return;
    // A superseded refresh may already have saved its nodes. Compare with
    // the running config so the next response can still apply those changes.
    final CompiledConfig updated;
    try {
      updated = compile();
    } on ConfigCompileException catch (exception) {
      _setError('订阅已更新，但无法应用到当前连接：${exception.message}');
      return;
    }
    if (!active.hasSameSubscriptionConfig(updated)) await restartCore();
  }

  Future<http.Response> _fetchSubscription(
    Uri uri, {
    required String userAgent,
  }) async {
    if (_disposed || _closing) throw const ParseException('订阅请求已取消');
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
    _subscriptionClients.add(client);
    Future<http.Response> download() async {
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
    }

    try {
      return await download().timeout(_subscriptionDownloadTimeout);
    } on TimeoutException {
      throw const ParseException('订阅下载超时，请稍后重试');
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
      _subscriptionClients.remove(client);
      client.close();
    }
  }

  void _cancelSubscriptionRequests() {
    _subscriptionUpdates.clear();
    for (final client in _subscriptionClients) {
      client.close();
    }
    _subscriptionClients.clear();
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
    await _saveSnapshot(snapshot);
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
    await _saveSnapshot(snapshot);
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
    await _saveSnapshot(snapshot);
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
    await _saveSnapshot(snapshot);
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
    await _replaceSnapshot(restored);
  }

  Future<void> resetAll() => _replaceSnapshot(AppSnapshot.empty());

  Future<void> _replaceSnapshot(AppSnapshot replacement) async {
    if (_replacingSnapshot) throw StateError('正在恢复本地数据');
    _replacingSnapshot = true;
    try {
      _cancelSubscriptionRequests();
      await disconnect();
      if (_disposed || _closing) return;
      await storage.save(replacement);
      if (_disposed || _closing) return;
      snapshot = replacement;
      _publishSettings();
    } finally {
      _replacingSnapshot = false;
    }
  }

  Future<void> setCpuWakeLockEnabled(bool enabled) async {
    final client = runtime;
    if (client is! AndroidRuntimeClient ||
        settings.cpuWakeLockEnabled == enabled) {
      return;
    }
    final current = settings;
    current.cpuWakeLockEnabled = enabled;
    try {
      await _saveSnapshot(snapshot);
    } catch (error) {
      if (current.cpuWakeLockEnabled == enabled) {
        current.cpuWakeLockEnabled = !enabled;
      }
      if (!_disposed) _setError('保存 CPU 唤醒锁设置失败：${_friendlyError(error)}');
      return;
    }
    if (_disposed || !identical(current, settings)) return;
    notifyListeners();
    try {
      await client.setCpuWakeLockEnabled(current.cpuWakeLockEnabled);
    } catch (error) {
      if (!_disposed) _setError('应用 CPU 唤醒锁设置失败：${_friendlyError(error)}');
    }
  }

  Future<void> saveSettings() async {
    await _saveSnapshot(snapshot);
    _publishSettings();
  }

  Future<void> setAppearance({
    ThemePreference? theme,
    int? seedColor,
    int? uiScalePercent,
  }) async {
    if (_appearanceSave != null ||
        _replacingSnapshot ||
        _closing ||
        _disposed) {
      throw StateError('暂时无法保存主题设置');
    }
    if (uiScalePercent != null &&
        !AppSettings.isValidUiScalePercent(uiScalePercent)) {
      throw ArgumentError.value(uiScalePercent, 'uiScalePercent');
    }
    final save = Completer<void>();
    _appearanceSave = save;
    try {
      if (_configApply != null) await _waitForAdvancedConfig();
      if (_changingWireGuard || _replacingSnapshot || _closing || _disposed) {
        throw StateError('暂时无法保存主题设置');
      }
      final current = settings;
      final nextTheme = theme ?? current.theme;
      final nextColor = seedColor ?? current.seedColor;
      final nextScale = uiScalePercent ?? current.uiScalePercent;
      if (nextTheme == current.theme &&
          nextColor == current.seedColor &&
          nextScale == current.uiScalePercent) {
        return;
      }

      final draft = AppSnapshot.fromJson(snapshot.toJson());
      draft.settings
        ..theme = nextTheme
        ..seedColor = nextColor
        ..uiScalePercent = nextScale;
      await storage.save(draft);
      current
        ..theme = nextTheme
        ..seedColor = nextColor
        ..uiScalePercent = nextScale;
      if (identical(current, settings)) _publishSettings();
    } finally {
      _appearanceSave = null;
      save.complete();
    }
  }

  Future<void> _saveSnapshot(AppSnapshot source) async {
    // Capture committed values even when a separate draft is being written.
    if (_configApply != null) await _waitForAdvancedConfig();
    if (_appearanceSave case final save?) await save.future;
    await storage.save(source);
  }

  void _publishSettings() {
    if (_disposed) return;
    appearanceTick.value++;
    notifyListeners();
  }

  Future<void> shutdownForExit() async {
    _closing = true;
    _cancelExitInfo();
    _subscriptionStartupTimer?.cancel();
    _subscriptionTimer?.cancel();
    _cancelSubscriptionRequests();
    _stopRuleSetUpdates();
    _pollTimer?.cancel();
    _uiTimer?.cancel();
    _pollGeneration++;
    _invalidateConnectionRefresh();
    _cancelNodeTests();
    await _connecting;
    await _waitForAdvancedConfig();
    if (_appearanceSave case final save?) await save.future;
    if (!initialized) return;
    await _restoreSystemProxy();
    await _stopTemporaryTestRuntime();
    await runtime.shutdown();
  }

  Future<void> _waitForAdvancedConfig() async {
    try {
      await _configApply;
    } catch (cause) {
      // The caller that applied the config reports the failure.
      debugPrint('Advanced config application ended: ${cause.runtimeType}');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscriptionStartupTimer?.cancel();
    _subscriptionTimer?.cancel();
    _cancelSubscriptionRequests();
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
    _nodeTestProgress.dispose();
    _proxyLatencyListeners.clear();
    super.dispose();
  }

  void _stopRuleSetUpdates() {
    _ruleSetUpdatesStopped = true;
    _ruleSetStartupTimer?.cancel();
    _ruleSetTimer?.cancel();
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
    _cancelNodeTests();
    _polling = false;
    connectedAt = null;
    error = message;
    await _restoreSystemProxy();
    // Stop the host runtime as well; on Android the VpnService and its TUN
    // survive an engine crash and would blackhole all device traffic.
    await runtime.shutdown();
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

class _ProxyLatencyNotifier extends ChangeNotifier {
  bool get isObserved => hasListeners;

  void publish() => notifyListeners();
}
