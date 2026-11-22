import 'dart:convert';

import 'wireguard_profile.dart';

export 'wireguard_profile.dart';

enum SplitMode { rule, global, direct }

enum SelectionMode { manual, auto }

enum NodeSortMode { manual, name, protocol, latency, favorite }

enum ThemePreference { system, light, dark }

enum StackMode { mixed, gvisor, system }

enum PerAppMode { off, allow, block }

enum AdvancedConfigMode { extension, override, off }

const builtInRuleSetTags = {
  'geosite-cn',
  'geoip-cn',
  'geosite-category-ads-all',
};

class BuiltInRuleDefinition {
  const BuiltInRuleDefinition({
    required this.id,
    required this.label,
    required this.kind,
    required this.value,
    required this.target,
    required this.defaultEnabled,
    this.logic = RuleLogic.single,
    this.conditions = const [],
  });

  final String id;
  final String label;
  final RuleKind kind;
  final String value;
  final RuleTarget target;
  final bool defaultEnabled;
  final RuleLogic logic;
  final List<RuleCondition> conditions;

  RoutingRule createRule() => RoutingRule(
    id: 'builtin-$id',
    name: label,
    kind: kind,
    value: value,
    target: target,
    enabled: defaultEnabled,
    builtInId: id,
    logic: logic,
    conditions: List.of(conditions),
  );
}

const _privateAddressRule = BuiltInRuleDefinition(
  id: 'private-address-direct',
  label: '私网地址直连',
  kind: RuleKind.privateIp,
  value: '',
  target: RuleTarget.direct,
  defaultEnabled: true,
);

const builtInRules = <BuiltInRuleDefinition>[
  _privateAddressRule,
  BuiltInRuleDefinition(
    id: 'quic-block',
    label: '屏蔽 QUIC',
    kind: RuleKind.port,
    value: '443',
    target: RuleTarget.block,
    defaultEnabled: true,
    logic: RuleLogic.and,
    conditions: [
      RuleCondition(kind: RuleKind.port, value: '443'),
      RuleCondition(kind: RuleKind.network, value: 'udp'),
    ],
  ),
  BuiltInRuleDefinition(
    id: 'geosite-category-ads-all',
    label: '广告与追踪域名',
    kind: RuleKind.ruleSet,
    value: 'geosite-category-ads-all',
    target: RuleTarget.block,
    defaultEnabled: false,
  ),
  BuiltInRuleDefinition(
    id: 'google-play',
    label: '中国 Play 商店规则',
    kind: RuleKind.domainSuffix,
    value: 'googleapis.cn',
    target: RuleTarget.proxy,
    defaultEnabled: true,
  ),
  BuiltInRuleDefinition(
    id: 'geosite-cn',
    label: '中国大陆域名',
    kind: RuleKind.ruleSet,
    value: 'geosite-cn',
    target: RuleTarget.direct,
    defaultEnabled: true,
  ),
  BuiltInRuleDefinition(
    id: 'geoip-cn',
    label: '中国大陆 IP',
    kind: RuleKind.ruleSet,
    value: 'geoip-cn',
    target: RuleTarget.direct,
    defaultEnabled: true,
  ),
];

List<String> splitRuleValues(String value) => value
    .split(RegExp(r'[\n,]'))
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toList();

List<String> splitRuleSetTags(String value) => splitRuleValues(value).map((
  tag,
) {
  final normalized = tag.toLowerCase();
  if (normalized.startsWith('geosite:') || normalized.startsWith('geoip:')) {
    return normalized.replaceFirst(':', '-');
  }
  return normalized;
}).toList();

class ProxyNode {
  ProxyNode({
    required this.id,
    required this.tag,
    required this.name,
    required this.outbound,
    this.subscriptionId,
    this.autoEnabled = true,
    this.favorite = false,
    this.createdAt,
  });

  final String id;
  final String tag;
  final String name;
  final Map<String, dynamic> outbound;
  final String? subscriptionId;
  bool autoEnabled;
  bool favorite;
  final DateTime? createdAt;

  String get protocol => (outbound['type'] as String?) ?? 'unknown';
  String get server => (outbound['server'] as String?) ?? '';
  int get port => (outbound['server_port'] as num?)?.toInt() ?? 0;

  ProxyNode copyWith({
    String? name,
    String? tag,
    Map<String, dynamic>? outbound,
    String? subscriptionId,
    bool? autoEnabled,
    bool? favorite,
  }) {
    return ProxyNode(
      id: id,
      tag: tag ?? this.tag,
      name: name ?? this.name,
      outbound: outbound ?? this.outbound,
      subscriptionId: subscriptionId ?? this.subscriptionId,
      autoEnabled: autoEnabled ?? this.autoEnabled,
      favorite: favorite ?? this.favorite,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'tag': tag,
    'name': name,
    'outbound': outbound,
    'subscriptionId': subscriptionId,
    'autoEnabled': autoEnabled,
    'favorite': favorite,
    'createdAt': createdAt?.toIso8601String(),
  };

  factory ProxyNode.fromJson(Map<String, dynamic> json) {
    return ProxyNode(
      id: json['id'] as String? ?? '',
      tag: json['tag'] as String? ?? '',
      name: json['name'] as String? ?? '',
      outbound: Map<String, dynamic>.from(json['outbound'] as Map? ?? const {}),
      subscriptionId: json['subscriptionId'] as String?,
      autoEnabled: json['autoEnabled'] as bool? ?? true,
      favorite: json['favorite'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }
}

class Subscription {
  Subscription({
    required this.id,
    required this.name,
    this.url = '',
    this.userAgent = '',
    this.updateIntervalMinutes = 0,
    this.autoUpdate = true,
    this.lastUpdated,
    this.lastError,
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expireAt,
    List<ProxyNode>? nodes,
    this.rawFormat = '',
    this.includeFilter = '',
    this.excludeFilter = '',
    this.sortMode = NodeSortMode.manual,
    this.sortDescending = false,
    this.autoEnabled = true,
  }) : nodes = List<ProxyNode>.of(nodes ?? const <ProxyNode>[]);

  final String id;
  String name;
  final String url;
  final String userAgent;
  int updateIntervalMinutes;
  bool autoUpdate;
  DateTime? lastUpdated;
  String? lastError;
  int? uploadBytes;
  int? downloadBytes;
  int? totalBytes;
  DateTime? expireAt;
  List<ProxyNode> nodes;
  final String rawFormat;
  String includeFilter;
  String excludeFilter;
  NodeSortMode sortMode;
  bool sortDescending;
  bool autoEnabled;

  bool get isUrlSubscription => url.isNotEmpty;

  static const minimumUpdateIntervalMinutes = 30;
  static const defaultUpdateIntervalMinutes = 24 * 60;
  static const maximumUpdateIntervalMinutes = 30 * 24 * 60;

  int get effectiveUpdateIntervalMinutes {
    final configured = updateIntervalMinutes;
    if (configured <= 0) return defaultUpdateIntervalMinutes;
    if (configured < minimumUpdateIntervalMinutes) {
      return minimumUpdateIntervalMinutes;
    }
    if (configured > maximumUpdateIntervalMinutes) {
      return maximumUpdateIntervalMinutes;
    }
    return configured;
  }

  bool isAutoUpdateDue(DateTime now) {
    if (!autoUpdate || !isUrlSubscription) return false;
    final updated = lastUpdated;
    return updated == null ||
        now.difference(updated) >=
            Duration(minutes: effectiveUpdateIntervalMinutes);
  }

  Subscription copyWith({
    String? name,
    String? url,
    String? userAgent,
    int? updateIntervalMinutes,
    bool? autoUpdate,
    List<ProxyNode>? nodes,
    DateTime? lastUpdated,
    String? lastError,
    bool clearError = false,
    String? includeFilter,
    String? excludeFilter,
    NodeSortMode? sortMode,
    bool? sortDescending,
    bool? autoEnabled,
  }) {
    return Subscription(
      id: id,
      name: name ?? this.name,
      url: url ?? this.url,
      userAgent: userAgent ?? this.userAgent,
      updateIntervalMinutes:
          updateIntervalMinutes ?? this.updateIntervalMinutes,
      autoUpdate: autoUpdate ?? this.autoUpdate,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      lastError: clearError ? null : (lastError ?? this.lastError),
      uploadBytes: uploadBytes,
      downloadBytes: downloadBytes,
      totalBytes: totalBytes,
      expireAt: expireAt,
      nodes: nodes ?? this.nodes,
      rawFormat: rawFormat,
      includeFilter: includeFilter ?? this.includeFilter,
      excludeFilter: excludeFilter ?? this.excludeFilter,
      sortMode: sortMode ?? this.sortMode,
      sortDescending: sortDescending ?? this.sortDescending,
      autoEnabled: autoEnabled ?? this.autoEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'userAgent': userAgent,
    'updateIntervalMinutes': updateIntervalMinutes,
    'autoUpdate': autoUpdate,
    'lastUpdated': lastUpdated?.toIso8601String(),
    'lastError': lastError,
    'uploadBytes': uploadBytes,
    'downloadBytes': downloadBytes,
    'totalBytes': totalBytes,
    'expireAt': expireAt?.toIso8601String(),
    'nodes': nodes.map((e) => e.toJson()).toList(),
    'rawFormat': rawFormat,
    'includeFilter': includeFilter,
    'excludeFilter': excludeFilter,
    'sortMode': sortMode.name,
    'sortDescending': sortDescending,
    'autoEnabled': autoEnabled,
  };

  factory Subscription.fromJson(
    Map<String, dynamic> json, {
    bool defaultAutoUpdate = true,
  }) {
    return Subscription(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      userAgent: json['userAgent'] as String? ?? '',
      updateIntervalMinutes:
          (json['updateIntervalMinutes'] as num?)?.toInt() ?? 0,
      autoUpdate: json['autoUpdate'] as bool? ?? defaultAutoUpdate,
      lastUpdated: DateTime.tryParse(json['lastUpdated'] as String? ?? ''),
      lastError: json['lastError'] as String?,
      uploadBytes: (json['uploadBytes'] as num?)?.toInt(),
      downloadBytes: (json['downloadBytes'] as num?)?.toInt(),
      totalBytes: (json['totalBytes'] as num?)?.toInt(),
      expireAt: DateTime.tryParse(json['expireAt'] as String? ?? ''),
      nodes: (json['nodes'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => ProxyNode.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      rawFormat: json['rawFormat'] as String? ?? '',
      includeFilter: json['includeFilter'] as String? ?? '',
      excludeFilter: json['excludeFilter'] as String? ?? '',
      sortMode: NodeSortMode.values.firstWhere(
        (e) => e.name == json['sortMode'],
        orElse: () => NodeSortMode.manual,
      ),
      sortDescending: json['sortDescending'] as bool? ?? false,
      autoEnabled: json['autoEnabled'] as bool? ?? true,
    );
  }
}

enum RuleKind {
  domain,
  domainSuffix,
  domainKeyword,
  domainRegex,
  privateIp,
  ipCidr,
  sourceIpCidr,
  port,
  sourcePort,
  network,
  protocol,
  processName,
  processPath,
  packageName,
  ruleSet;

  bool get takesValue => this != RuleKind.privateIp;
}

enum RuleTarget { proxy, direct, block, manualGroup, autoGroup }

enum RuleLogic { single, and, or }

class RuleCondition {
  const RuleCondition({required this.kind, required this.value});

  final RuleKind kind;
  final String value;

  Map<String, dynamic> toJson() => {'kind': kind.name, 'value': value};

  factory RuleCondition.fromJson(Map<String, dynamic> json) {
    return RuleCondition(
      kind: RuleKind.values.firstWhere(
        (e) => e.name == json['kind'],
        orElse: () => RuleKind.domainSuffix,
      ),
      value: json['value'] as String? ?? '',
    );
  }
}

class RoutingRule {
  RoutingRule({
    required this.id,
    required this.name,
    required this.kind,
    required this.value,
    required this.target,
    this.enabled = true,
    this.logic = RuleLogic.single,
    List<RuleCondition>? conditions,
    this.builtInId,
  }) : conditions = conditions ?? [];

  final String id;
  String name;
  final RuleKind kind;
  String value;
  RuleTarget target;
  bool enabled;
  RuleLogic logic;
  List<RuleCondition> conditions;
  final String? builtInId;

  bool get isLogical => logic != RuleLogic.single && conditions.length >= 2;

  List<RuleCondition> get effectiveConditions => isLogical
      ? List.of(conditions)
      : [RuleCondition(kind: kind, value: value)];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'value': value,
    'target': target.name,
    'enabled': enabled,
    'logic': logic.name,
    'conditions': conditions.map((e) => e.toJson()).toList(),
    'builtInId': builtInId,
  };

  factory RoutingRule.fromJson(Map<String, dynamic> json) {
    return RoutingRule(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      kind: RuleKind.values.firstWhere(
        (e) => e.name == json['kind'],
        orElse: () => RuleKind.domainSuffix,
      ),
      value: json['value'] as String? ?? '',
      target: RuleTarget.values.firstWhere(
        (e) => e.name == json['target'],
        orElse: () => RuleTarget.proxy,
      ),
      enabled: json['enabled'] as bool? ?? true,
      logic: RuleLogic.values.firstWhere(
        (e) => e.name == json['logic'],
        orElse: () => RuleLogic.single,
      ),
      conditions: (json['conditions'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => RuleCondition.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      builtInId: json['builtInId'] as String?,
    );
  }
}

class DnsSettings {
  DnsSettings({
    this.directServer = defaultDirectServer,
    this.proxyServer = defaultProxyServer,
    this.strategy = 'prefer_ipv4',
    this.dnsRouting = true,
    this.sniff = true,
    this.reverseMapping = true,
    this.timeout = '10s',
  });

  static const defaultDirectServer = 'https://dns.alidns.com/dns-query';
  static const defaultProxyServer = 'https://dns.cloudflare.com/dns-query';

  /// Bootstraps the DoH hostnames above. Android has no resolv.conf, so the
  /// system resolver is unusable before the tunnel exists; a plain UDP server
  /// at a fixed address always answers.
  static const bootstrapServer = '223.5.5.5';

  String directServer;
  String proxyServer;
  String strategy;
  bool dnsRouting;
  bool sniff;
  bool reverseMapping;
  String timeout;

  Map<String, dynamic> toJson() => {
    'directServer': directServer,
    'proxyServer': proxyServer,
    'strategy': strategy,
    'dnsRouting': dnsRouting,
    'sniff': sniff,
    'reverseMapping': reverseMapping,
    'timeout': timeout,
  };

  factory DnsSettings.fromJson(Map<String, dynamic> json) {
    return DnsSettings(
      directServer: json['directServer'] as String? ?? defaultDirectServer,
      proxyServer: json['proxyServer'] as String? ?? defaultProxyServer,
      strategy: json['strategy'] as String? ?? 'prefer_ipv4',
      dnsRouting: json['dnsRouting'] as bool? ?? true,
      sniff: json['sniff'] as bool? ?? true,
      reverseMapping: json['reverseMapping'] as bool? ?? true,
      timeout: json['timeout'] as String? ?? '10s',
    );
  }
}

class InboundSettings {
  InboundSettings({
    this.localPort = 2080,
    this.allowLan = false,
    this.authUsername = '',
    this.authPassword = '',
    this.sniff = true,
  });

  int localPort;
  bool allowLan;
  String authUsername;
  String authPassword;
  bool sniff;

  Map<String, dynamic> toJson() => {
    'localPort': localPort,
    'allowLan': allowLan,
    'authUsername': authUsername,
    'authPassword': authPassword,
    'sniff': sniff,
  };

  factory InboundSettings.fromJson(Map<String, dynamic> json) {
    return InboundSettings(
      localPort: (json['localPort'] as num?)?.toInt() ?? 2080,
      allowLan: json['allowLan'] as bool? ?? false,
      authUsername: json['authUsername'] as String? ?? '',
      authPassword: json['authPassword'] as String? ?? '',
      sniff: json['sniff'] as bool? ?? true,
    );
  }
}

class TunSettings {
  TunSettings({
    this.mtu = 9000,
    this.stack = StackMode.mixed,
    this.ipv6 = false,
    this.strictRoute = true,
    this.autoRoute = true,
    this.bypassLan = true,
  });

  int mtu;
  StackMode stack;
  bool ipv6;
  bool strictRoute;
  bool autoRoute;
  bool bypassLan;

  Map<String, dynamic> toJson() => {
    'mtu': mtu,
    'stack': stack.name,
    'ipv6': ipv6,
    'strictRoute': strictRoute,
    'autoRoute': autoRoute,
    'bypassLan': bypassLan,
  };

  factory TunSettings.fromJson(Map<String, dynamic> json) {
    return TunSettings(
      mtu: (json['mtu'] as num?)?.toInt() ?? 9000,
      stack: StackMode.values.firstWhere(
        (e) => e.name == json['stack'],
        orElse: () => StackMode.mixed,
      ),
      ipv6: json['ipv6'] as bool? ?? false,
      strictRoute: json['strictRoute'] as bool? ?? true,
      autoRoute: json['autoRoute'] as bool? ?? true,
      bypassLan: json['bypassLan'] as bool? ?? true,
    );
  }
}

class AdvancedSettings {
  static const _defaultUrlTestTolerance = 50;
  static const _defaultInterruptExistingConnections = true;

  AdvancedSettings({
    this.logLevel = 'info',
    this.urlTestUrl = 'http://www.gstatic.com/generate_204',
    this.urlTestInterval = '3m',
    this.urlTestTolerance = _defaultUrlTestTolerance,
    this.urlTestIdleTimeout = '30m',
    this.interruptExistingConnections = _defaultInterruptExistingConnections,
  });

  String logLevel;
  String urlTestUrl;
  String urlTestInterval;
  int urlTestTolerance;
  String urlTestIdleTimeout;
  bool interruptExistingConnections;

  Map<String, dynamic> toJson() => {
    'logLevel': logLevel,
    'urlTestUrl': urlTestUrl,
    'urlTestInterval': urlTestInterval,
    'urlTestTolerance': urlTestTolerance,
    'urlTestIdleTimeout': urlTestIdleTimeout,
    'interruptExistingConnections': interruptExistingConnections,
  };

  factory AdvancedSettings.fromJson(Map<String, dynamic> json) {
    return AdvancedSettings(
      logLevel: json['logLevel'] as String? ?? 'info',
      urlTestUrl:
          json['urlTestUrl'] as String? ??
          'http://www.gstatic.com/generate_204',
      urlTestInterval: json['urlTestInterval'] as String? ?? '3m',
      urlTestTolerance:
          (json['urlTestTolerance'] as num?)?.toInt() ??
          _defaultUrlTestTolerance,
      urlTestIdleTimeout: json['urlTestIdleTimeout'] as String? ?? '30m',
      interruptExistingConnections:
          json['interruptExistingConnections'] as bool? ??
          _defaultInterruptExistingConnections,
    );
  }
}

class ProxyOverride {
  ProxyOverride({this.enabled = false, this.server = '', this.bypass = ''});

  bool enabled;
  String server;
  String bypass;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'server': server,
    'bypass': bypass,
  };

  factory ProxyOverride.fromJson(Map<String, dynamic> json) {
    return ProxyOverride(
      enabled: json['enabled'] as bool? ?? false,
      server: json['server'] as String? ?? '',
      bypass: json['bypass'] as String? ?? '',
    );
  }
}

enum HomeCard {
  connection,
  splitMode,
  traffic,
  subscription,
  services,
  activity,
}

const _previousDefaultHomeCardOrder = [
  HomeCard.connection,
  HomeCard.splitMode,
  HomeCard.traffic,
  HomeCard.subscription,
  HomeCard.activity,
  HomeCard.services,
];

class HomeLayout {
  HomeLayout({List<HomeCard>? order, Set<HomeCard>? hidden})
    : order = <HomeCard>{...?order, ...HomeCard.values}.toList(),
      hidden = {...?hidden}..remove(HomeCard.connection) {
    if (order != null && !order.contains(HomeCard.splitMode)) {
      // Add the shortcut to existing layouts without reordering their cards.
      this.order.remove(HomeCard.splitMode);
      this.order.insert(
        this.order.indexOf(HomeCard.connection) + 1,
        HomeCard.splitMode,
      );
    }
    // The connection card always occupies the first row on the home page.
    this.order.remove(HomeCard.connection);
    this.order.insert(0, HomeCard.connection);
  }

  final List<HomeCard> order;
  final Set<HomeCard> hidden;

  Map<String, dynamic> toJson() => {
    'order': order.map((card) => card.name).toList(),
    'hidden': hidden.map((card) => card.name).toList(),
  };

  factory HomeLayout.fromJson(Object? value) {
    if (value is! Map) return HomeLayout();
    List<HomeCard> parse(Object? names) => names is List
        ? names
              .map(
                (name) => HomeCard.values
                    .where((card) => card.name == name)
                    .firstOrNull,
              )
              .whereType<HomeCard>()
              .toList()
        : [];
    final savedOrder = parse(value['order']);
    final layout = HomeLayout(
      order: savedOrder,
      hidden: parse(value['hidden']).toSet(),
    );
    final order = layout.order;
    final wasDefaultOrder =
        savedOrder.firstOrNull == HomeCard.connection &&
        order.length == _previousDefaultHomeCardOrder.length &&
        order.asMap().entries.every(
          (entry) => entry.value == _previousDefaultHomeCardOrder[entry.key],
        );
    if (wasDefaultOrder) {
      order.remove(HomeCard.services);
      order.insert(order.indexOf(HomeCard.activity), HomeCard.services);
    }
    return layout;
  }
}

class AppSettings {
  AppSettings({
    this.theme = ThemePreference.system,
    this.seedColor = 0xFF0E7490,
    this.splitMode = SplitMode.rule,
    this.selectionMode = SelectionMode.manual,
    this.manualNodeId,
    this.perAppMode = PerAppMode.off,
    List<String>? perAppPackages,
    this.systemProxyEnabled = false,
    this.tunEnabled = false,
    this.vpnEnabled = true,
    this.autoConnect = false,
    this.cpuWakeLockEnabled = false,
    this.startAtLogin = false,
    this.minimizeToTray = true,
    this.ruleSetAutoUpdate = true,
    this.dns,
    this.inbound,
    this.tun,
    this.advanced,
    this.proxyOverride,
    HomeLayout? homeDesktop,
    HomeLayout? homeMobile,
  }) : perAppPackages = perAppPackages ?? [],
       homeDesktop = homeDesktop ?? HomeLayout(),
       homeMobile = homeMobile ?? HomeLayout();

  ThemePreference theme;
  int seedColor;
  SplitMode splitMode;
  SelectionMode selectionMode;
  String? manualNodeId;
  PerAppMode perAppMode;
  List<String> perAppPackages;
  bool systemProxyEnabled;
  bool tunEnabled;
  bool vpnEnabled;
  bool autoConnect;
  bool cpuWakeLockEnabled;
  bool startAtLogin;
  bool minimizeToTray;
  bool ruleSetAutoUpdate;
  DnsSettings? dns;
  InboundSettings? inbound;
  TunSettings? tun;
  AdvancedSettings? advanced;
  ProxyOverride? proxyOverride;
  HomeLayout homeDesktop;
  HomeLayout homeMobile;

  DnsSettings get dnsOrDefault => dns ??= DnsSettings();
  InboundSettings get inboundOrDefault => inbound ??= InboundSettings();
  TunSettings get tunOrDefault => tun ??= TunSettings();
  AdvancedSettings get advancedOrDefault => advanced ??= AdvancedSettings();
  ProxyOverride get proxyOverrideOrDefault => proxyOverride ??= ProxyOverride();

  Map<String, dynamic> toJson() => {
    'theme': theme.name,
    'seedColor': seedColor,
    'splitMode': splitMode.name,
    'selectionMode': selectionMode.name,
    'manualNodeId': manualNodeId,
    'perAppMode': perAppMode.name,
    'perAppPackages': perAppPackages,
    'systemProxyEnabled': systemProxyEnabled,
    'tunEnabled': tunEnabled,
    'vpnEnabled': vpnEnabled,
    'autoConnect': autoConnect,
    'cpuWakeLockEnabled': cpuWakeLockEnabled,
    'startAtLogin': startAtLogin,
    'minimizeToTray': minimizeToTray,
    'ruleSetAutoUpdate': ruleSetAutoUpdate,
    'dns': dnsOrDefault.toJson(),
    'inbound': inboundOrDefault.toJson(),
    'tun': tunOrDefault.toJson(),
    'advanced': advancedOrDefault.toJson(),
    'proxyOverride': proxyOverrideOrDefault.toJson(),
    'homeDesktop': homeDesktop.toJson(),
    'homeMobile': homeMobile.toJson(),
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      theme: ThemePreference.values.firstWhere(
        (e) => e.name == json['theme'],
        orElse: () => ThemePreference.system,
      ),
      seedColor: (json['seedColor'] as num?)?.toInt() ?? 0xFF0E7490,
      splitMode: SplitMode.values.firstWhere(
        (e) => e.name == json['splitMode'],
        orElse: () => SplitMode.rule,
      ),
      selectionMode: SelectionMode.values.firstWhere(
        (e) => e.name == json['selectionMode'],
        orElse: () => SelectionMode.manual,
      ),
      manualNodeId: json['manualNodeId'] as String?,
      homeDesktop: HomeLayout.fromJson(json['homeDesktop']),
      homeMobile: HomeLayout.fromJson(json['homeMobile']),
      perAppMode: PerAppMode.values.firstWhere(
        (e) => e.name == json['perAppMode'],
        orElse: () => PerAppMode.off,
      ),
      perAppPackages: (json['perAppPackages'] as List?)
          ?.map((e) => e.toString())
          .toList(growable: false),
      systemProxyEnabled: json['systemProxyEnabled'] as bool? ?? false,
      tunEnabled: json['tunEnabled'] as bool? ?? false,
      vpnEnabled: json['vpnEnabled'] as bool? ?? true,
      autoConnect: json['autoConnect'] as bool? ?? false,
      cpuWakeLockEnabled: json['cpuWakeLockEnabled'] as bool? ?? false,
      startAtLogin: json['startAtLogin'] as bool? ?? false,
      minimizeToTray: json['minimizeToTray'] as bool? ?? true,
      ruleSetAutoUpdate: json['ruleSetAutoUpdate'] as bool? ?? true,
      dns: json['dns'] is Map
          ? DnsSettings.fromJson(Map<String, dynamic>.from(json['dns'] as Map))
          : null,
      inbound: json['inbound'] is Map
          ? InboundSettings.fromJson(
              Map<String, dynamic>.from(json['inbound'] as Map),
            )
          : null,
      tun: json['tun'] is Map
          ? TunSettings.fromJson(Map<String, dynamic>.from(json['tun'] as Map))
          : null,
      advanced: json['advanced'] is Map
          ? AdvancedSettings.fromJson(
              Map<String, dynamic>.from(json['advanced'] as Map),
            )
          : null,
      proxyOverride: json['proxyOverride'] is Map
          ? ProxyOverride.fromJson(
              Map<String, dynamic>.from(json['proxyOverride'] as Map),
            )
          : null,
    );
  }
}

class AppSnapshot {
  AppSnapshot({
    required this.settings,
    required this.subscriptions,
    List<RoutingRule>? rules,
    this.advancedJson = const {},
    this.inactiveAdvancedJson,
    this.customConfig = '',
    this.useCustomConfig = false,
    this.installedAt,
    OutboundMode outboundMode = OutboundMode.proxy,
    bool? chainProxyEnabled,
    StandaloneOutbound? standaloneOutbound,
    this.wireGuardProfileId,
    this.wireGuardProfiles = const [],
    List<WireGuardGroup>? wireGuardGroups,
    this.nodeGroupOrder = const [],
  }) : rules = rules ?? [],
       chainProxyEnabled =
           chainProxyEnabled ?? outboundMode == OutboundMode.wireGuardProxy,
       standaloneOutbound =
           standaloneOutbound ??
           (outboundMode == OutboundMode.wireGuard
               ? StandaloneOutbound.wireGuard
               : StandaloneOutbound.singBox),
       wireGuardGroups =
           wireGuardGroups ??
           (wireGuardProfiles.isEmpty ? [] : [WireGuardGroup.legacy]);

  AppSettings settings;
  List<Subscription> subscriptions;
  List<RoutingRule> rules;
  Map<String, dynamic> advancedJson;
  Map<String, dynamic>? inactiveAdvancedJson;
  String customConfig;
  bool useCustomConfig;
  Map<String, dynamic> get advancedJsonDraft =>
      inactiveAdvancedJson ?? advancedJson;
  AdvancedConfigMode get advancedConfigMode => useCustomConfig
      ? AdvancedConfigMode.override
      : inactiveAdvancedJson != null
      ? AdvancedConfigMode.off
      : AdvancedConfigMode.extension;
  DateTime? installedAt;
  bool chainProxyEnabled;
  StandaloneOutbound standaloneOutbound;
  List<WireGuardGroup> wireGuardGroups;
  List<String> nodeGroupOrder;

  static String subscriptionGroupKey(String id) => 'subscription:$id';
  static String wireGuardGroupKey(String id) => 'wireguard:$id';
  static const otherNodeGroupKey = 'other';

  List<String> get orderedNodeGroupKeys {
    final remaining = {
      for (final group in subscriptions) subscriptionGroupKey(group.id),
      otherNodeGroupKey,
      for (final group in wireGuardGroups) wireGuardGroupKey(group.id),
    };
    return [
      for (final key in nodeGroupOrder)
        if (remaining.remove(key)) key,
      ...remaining,
    ];
  }

  OutboundMode get outboundMode => chainProxyEnabled
      ? OutboundMode.wireGuardProxy
      : standaloneOutbound == StandaloneOutbound.wireGuard
      ? OutboundMode.wireGuard
      : OutboundMode.proxy;
  set outboundMode(OutboundMode mode) {
    chainProxyEnabled = mode == OutboundMode.wireGuardProxy;
    if (!chainProxyEnabled) {
      standaloneOutbound = mode == OutboundMode.wireGuard
          ? StandaloneOutbound.wireGuard
          : StandaloneOutbound.singBox;
    }
  }

  String? wireGuardProfileId;
  List<WireGuardProfile> wireGuardProfiles;

  WireGuardProfile? get wireGuardProfile {
    for (final profile in wireGuardProfiles) {
      if (profile.id == wireGuardProfileId) return profile;
    }
    return null;
  }

  static const formatVersion = 2;

  List<ProxyNode> get allNodes => [
    for (final sub in subscriptions) ...sub.nodes,
  ];

  bool get hasNodes => subscriptions.any((group) => group.nodes.isNotEmpty);

  int pruneDuplicateNodeIds() {
    final seen = <String>{};
    var removed = 0;
    for (final subscription in subscriptions) {
      subscription.nodes.removeWhere((node) {
        if (seen.add(node.id)) return false;
        removed++;
        return true;
      });
    }
    return removed;
  }

  ProxyNode? nodeById(String? id) {
    if (id == null) return null;
    for (final group in subscriptions) {
      for (final node in group.nodes) {
        if (node.id == id) return node;
      }
    }
    return null;
  }

  Set<String> activeRuleSetTags(bool Function(String) isAvailable) => {
    for (final rule in rules)
      if (rule.enabled)
        for (final condition in rule.effectiveConditions)
          if (condition.kind == RuleKind.ruleSet)
            ...splitRuleSetTags(condition.value).where(isAvailable),
  };

  Set<String> get activeBuiltInRuleSets =>
      activeRuleSetTags(builtInRuleSetTags.contains);

  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'routingDefaultsVersion': 1,
    'settings': settings.toJson(),
    'subscriptions': subscriptions.map((e) => e.toJson()).toList(),
    'rules': rules.map((e) => e.toJson()).toList(),
    'advancedJson': advancedJson,
    // Older releases read only the active JSON and will keep a paused extension off.
    'inactiveAdvancedJson': ?inactiveAdvancedJson,
    'customConfig': customConfig,
    'useCustomConfig': useCustomConfig,
    'outboundMode': outboundMode.name,
    'chainProxyEnabled': chainProxyEnabled,
    'standaloneOutbound': standaloneOutbound.name,
    'wireGuardGroups': wireGuardGroups.map((group) => group.toJson()).toList(),
    if (nodeGroupOrder.isNotEmpty) 'nodeGroupOrder': nodeGroupOrder,
    'wireGuardProfileId': wireGuardProfileId,
    'wireGuardProfiles': wireGuardProfiles.map((e) => e.toJson()).toList(),
    'installedAt': installedAt?.toIso8601String(),
  };

  factory AppSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('不支持的数据格式版本');
    }
    if (json['settings'] is! Map ||
        json['subscriptions'] is! List ||
        json['rules'] is! List ||
        json['advancedJson'] is! Map) {
      throw const FormatException('状态数据结构无效');
    }

    final settingsJson = Map<String, dynamic>.from(json['settings'] as Map);
    // Older snapshots used one global switch; carry its value into subscriptions
    // that do not have their own setting yet.
    final legacyAutoUpdate =
        settingsJson['subscriptionAutoUpdate'] as bool? ?? true;
    final rules = (json['rules'] as List)
        .cast<Map>()
        .map((item) => RoutingRule.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    // Old snapshots predate the editable rule that replaces the compiler's
    // implicit private-address routing. Do not restore it after user deletion.
    if (json['routingDefaultsVersion'] == null &&
        !rules.any((rule) => rule.builtInId == _privateAddressRule.id)) {
      rules.insert(0, _privateAddressRule.createRule());
    }
    return AppSnapshot(
      settings: AppSettings.fromJson(settingsJson),
      subscriptions: (json['subscriptions'] as List)
          .cast<Map>()
          .map(
            (item) => Subscription.fromJson(
              Map<String, dynamic>.from(item),
              defaultAutoUpdate: legacyAutoUpdate,
            ),
          )
          .toList(),
      rules: rules,
      advancedJson: Map<String, dynamic>.from(json['advancedJson'] as Map),
      inactiveAdvancedJson: json['inactiveAdvancedJson'] is Map
          ? Map<String, dynamic>.from(json['inactiveAdvancedJson'] as Map)
          : null,
      customConfig: json['customConfig'] as String? ?? '',
      useCustomConfig: json['useCustomConfig'] as bool? ?? false,
      outboundMode: OutboundMode.values.firstWhere(
        (mode) => mode.name == json['outboundMode'],
        orElse: () => OutboundMode.proxy,
      ),
      chainProxyEnabled: json['chainProxyEnabled'] as bool?,
      standaloneOutbound: StandaloneOutbound.values
          .where((mode) => mode.name == json['standaloneOutbound'])
          .firstOrNull,
      wireGuardGroups: (json['wireGuardGroups'] as List?)
          ?.map(
            (group) => WireGuardGroup.fromJson(
              Map<String, dynamic>.from(group as Map),
            ),
          )
          .toList(),
      wireGuardProfileId: json['wireGuardProfileId'] as String?,
      nodeGroupOrder: switch (json['nodeGroupOrder']) {
        final List order => order.whereType<String>().toList(),
        _ => const [],
      },
      wireGuardProfiles: (json['wireGuardProfiles'] as List? ?? const [])
          .map(
            (profile) => WireGuardProfile.fromJson(
              Map<String, dynamic>.from(profile as Map),
            ),
          )
          .toList(),
      installedAt: DateTime.tryParse(json['installedAt'] as String? ?? ''),
    );
  }

  factory AppSnapshot.empty() => AppSnapshot(
    settings: AppSettings(),
    subscriptions: [],
    installedAt: DateTime.now(),
    rules: [for (final definition in builtInRules) definition.createRule()],
  );

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}
