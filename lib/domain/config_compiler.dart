import 'dart:convert';
import 'dart:io';

import 'cidr_routes.dart';
import 'config_policy.dart';
import 'models.dart';

class ConfigCompileException implements Exception {
  const ConfigCompileException(this.message, {this.violations = const []});

  final String message;
  final List<PolicyViolation> violations;

  @override
  String toString() => message;
}

enum CompileTarget { windows, android, linux }

bool _hasTunInbound(Object? inbounds) =>
    inbounds is List &&
    inbounds.any((item) => item is Map && item['type'] == 'tun');

class CompiledConfig {
  const CompiledConfig({
    required this.json,
    required this.encoded,
    required this.warnings,
    required this.nodeTags,
    required this.proxyGroupTag,
    required this.autoGroupTag,
    required this.custom,
    this.routeRuleNames = const {},
  });

  final Map<String, dynamic> json;
  final String encoded;
  final List<String> warnings;
  final Map<String, String> nodeTags;
  final String proxyGroupTag;
  final String autoGroupTag;
  final bool custom;
  final Map<int, String> routeRuleNames;

  Iterable<String> get localRuleSetPaths sync* {
    final route = json['route'];
    if (route is! Map) return;
    final ruleSets = route['rule_set'];
    if (ruleSets is! List) return;
    for (final entry in ruleSets) {
      if (entry is! Map || entry['type'] != 'local') continue;
      final path = entry['path'];
      if (path is String) yield path;
    }
  }

  bool get hasTunInbound => _hasTunInbound(json['inbounds']);

  static const _hidden = '<已隐藏>';
  static const _credentialFields = {
    'auth',
    'auth_str',
    'password',
    'username',
    'uuid',
    'secret',
    'token',
    'private_key',
    'pre_shared_key',
    'api_key',
    'authorization',
    'proxy-authorization',
    'cookie',
    'x-api-key',
  };
  static final _credentialSuffix = RegExp(
    r'_(password|username|passphrase|token|secret|private_key|api_key)$',
  );

  Map<String, dynamic> get redactedJson => _redactFields(json);

  static bool containsRedactedValue(Object? value) => switch (value) {
    Map() => value.values.any(containsRedactedValue),
    List() => value.any(containsRedactedValue),
    _ => value == _hidden,
  };

  static Map<String, dynamic> _redactFields(Map fields) => {
    for (final entry in fields.entries)
      if (entry.key case final String key) key: _redactField(key, entry.value),
  };

  static Object? _redactField(String key, Object? value) {
    final name = key.toLowerCase();
    if (_credentialFields.contains(name) || _credentialSuffix.hasMatch(name)) {
      return _hidden;
    }
    if ((name == 'headers' || name.endsWith('_headers')) && value is Map) {
      return {for (final key in value.keys) key: _hidden};
    }
    return _redact(value);
  }

  static Object? _redact(Object? value) {
    if (value is List) return value.map(_redact).toList();
    if (value is Map) return _redactFields(value);
    if (value is String && value.contains('://')) {
      final uri = Uri.tryParse(value);
      if (uri != null &&
          uri.hasAuthority &&
          (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment)) {
        return _hidden;
      }
    }
    return value;
  }
}

class RoutingPreview {
  const RoutingPreview({
    required this.coreRules,
    required this.activeRuleIds,
    required this.finalOutbound,
    required this.overridden,
  });

  final List<Map<String, dynamic>> coreRules;
  final Set<String> activeRuleIds;
  final String? finalOutbound;
  final bool overridden;
}

class ConfigCompiler {
  ConfigCompiler._();

  static const proxyTag = 'proxy';
  static const autoTag = 'auto';
  static const directTag = 'direct';
  static const mixedTag = 'mixed-in';
  static const tunTag = 'tun-in';
  static const bootstrapTag = 'dns-bootstrap';
  static const systemTag = 'dns-system';
  static const wireGuardTag = 'neko-wireguard';
  static const physicalTag = 'neko-physical';
  static const wireGuardDnsTag = 'neko-wireguard-dns';
  static const wireGuardBootstrapTag = 'neko-wireguard-bootstrap';

  static String nodeTag(ProxyNode node) => 'node-${node.id}';

  static Iterable<ProxyNode> autoCandidates(
    Iterable<ProxyNode> nodes,
    Iterable<Subscription> subscriptions,
  ) {
    final disabledGroupIds = {
      for (final group in subscriptions)
        if (!group.autoEnabled) group.id,
    };
    return nodes.where(
      (node) =>
          node.autoEnabled && !disabledGroupIds.contains(node.subscriptionId),
    );
  }

  static String ruleSetDirectory(String cachePath) {
    final forward = cachePath.lastIndexOf('/');
    final backward = cachePath.lastIndexOf('\\');
    final index = forward > backward ? forward : backward;
    if (index < 0) return 'rules';
    final separator = index == forward ? '/' : '\\';
    return '${cachePath.substring(0, index)}${separator}rules';
  }

  static String _ruleSetPath(String directory, String name) {
    final forward = directory.lastIndexOf('/');
    final backward = directory.lastIndexOf('\\');
    final separator = forward > backward ? '/' : '\\';
    return '$directory$separator$name';
  }

  static CompiledConfig compile(
    AppSnapshot snapshot, {
    required CompileTarget target,
    required String cachePath,
    Map<String, String>? ruleSetPaths,
    String? logPath,
    bool testOnly = false,
    List<String> systemDnsServers = const [],
  }) {
    if (snapshot.useCustomConfig) {
      if (testOnly) {
        throw const ConfigCompileException('完整自定义配置无法映射节点标签，未连接时不能测速，请先连接。');
      }
      return _compileCustom(snapshot, target);
    }

    final wireGuardOnly = snapshot.outboundMode == OutboundMode.wireGuard;
    final WireGuardConfig? wireGuard;
    if (snapshot.outboundMode == OutboundMode.proxy) {
      wireGuard = null;
    } else {
      final profile = snapshot.wireGuardProfile;
      if (profile == null) {
        throw const ConfigCompileException('请选择 WireGuard 配置。');
      }
      try {
        wireGuard = profile.parse();
      } on FormatException catch (error) {
        throw ConfigCompileException(error.message);
      }
      if (snapshot.advancedJson.keys.any(
        const {
          'inbounds',
          'outbounds',
          'endpoints',
          'dns',
          'route',
          'services',
          'http_clients',
        }.contains,
      )) {
        throw const ConfigCompileException(
          '高级 JSON 与 WireGuard 的入站、出站或 DNS 配置冲突。',
        );
      }
    }

    final seenIds = <String>{};
    final nodes = (wireGuardOnly ? const <ProxyNode>[] : snapshot.allNodes)
        .where(
          (node) => _isSupportedOutbound(node.outbound) && seenIds.add(node.id),
        )
        .toList();
    if (nodes.isEmpty && !wireGuardOnly) {
      throw const ConfigCompileException('没有可用的节点，请先导入订阅或节点。');
    }

    final warnings = <String>[];
    final settings = snapshot.settings;
    final useTun = target == CompileTarget.android
        ? settings.vpnEnabled
        : settings.tunEnabled;
    final selectionAuto = settings.selectionMode == SelectionMode.auto;
    final autoNodes = autoCandidates(nodes, snapshot.subscriptions).toList();
    final useAuto = selectionAuto && autoNodes.isNotEmpty;
    if (selectionAuto && autoNodes.isEmpty) {
      warnings.add('自动选择没有候选节点，已暂时使用手动选择。');
    }
    final proxyGroupTag = useAuto ? autoTag : proxyTag;

    // IDs are already unique, and nodeTag maps each ID to a unique tag.
    final nodeTags = {for (final node in nodes) node.id: nodeTag(node)};

    final manualNode = snapshot.nodeById(settings.manualNodeId);
    final selectedTag =
        manualNode != null && nodeTags.containsKey(manualNode.id)
        ? nodeTags[manualNode.id]
        : nodes.isEmpty
        ? null
        : nodeTags[nodes.first.id];

    final outbounds = <Map<String, dynamic>>[
      {
        'type': 'direct',
        'tag': directTag,
        // A completely empty direct outbound is rejected when used as a DNS
        // detour, so keep a harmless explicit dialer option.
        'connect_timeout': '10s',
      },
    ];

    if (!wireGuardOnly) {
      outbounds.add({
        'type': 'selector',
        'tag': proxyTag,
        'outbounds': [for (final node in nodes) nodeTags[node.id]!],
        'default': selectedTag,
      });
    }

    if (!testOnly && autoNodes.isNotEmpty) {
      // Until the first urltest finishes, sing-box selects the group's first
      // outbound. Start from the node the user chose last instead of whatever
      // happens to come first in the subscription.
      final autoCandidates = [...autoNodes];
      final manualIndex = manualNode == null
          ? -1
          : autoCandidates.indexWhere((node) => node.id == manualNode.id);
      if (manualIndex > 0) {
        autoCandidates.insert(0, autoCandidates.removeAt(manualIndex));
      }
      outbounds.add({
        'type': 'urltest',
        'tag': autoTag,
        'outbounds': [for (final node in autoCandidates) nodeTags[node.id]!],
        'url': settings.advancedOrDefault.urlTestUrl,
        'interval': settings.advancedOrDefault.urlTestInterval,
        'tolerance': settings.advancedOrDefault.urlTestTolerance,
        'idle_timeout': settings.advancedOrDefault.urlTestIdleTimeout,
        'interrupt_exist_connections':
            settings.advancedOrDefault.interruptExistingConnections,
      });
    }

    for (final node in nodes) {
      final outbound = Map<String, dynamic>.from(node.outbound);
      if (outbound.remove('detour') != null) {
        warnings.add('节点「${node.name}」的 detour 引用未包含在订阅中，已忽略。');
      }
      if (outbound.remove('domain_resolver') != null) {
        warnings.add('节点「${node.name}」的 domain_resolver 引用未包含在订阅中，已忽略。');
      }
      outbound['tag'] = nodeTags[node.id]!;
      outbounds.add(outbound);
    }

    final systemDns = _systemDnsAddress(systemDnsServers);
    final availableRuleSets =
        ruleSetPaths ??
        {
          for (final tag in builtInRuleSetTags)
            tag: _ruleSetPath(ruleSetDirectory(cachePath), '$tag.srs'),
        };
    final activeRuleSets = !testOnly && settings.splitMode == SplitMode.rule
        ? snapshot.activeRuleSetTags(availableRuleSets.containsKey)
        : const <String>{};
    final dns = testOnly
        ? _buildTestDns(snapshot, warnings, systemDns)
        : _buildDns(
            snapshot,
            target,
            useTun,
            proxyGroupTag,
            warnings,
            systemDns,
            activeRuleSets,
          );
    final editableRules = <int, RoutingRule>{};
    final route = testOnly
        ? <String, dynamic>{
            'final': proxyTag,
            'default_domain_resolver': {
              'server': systemDns == null ? 'dns-direct' : systemTag,
            },
          }
        : _buildRoute(
            snapshot,
            useTun,
            proxyGroupTag,
            autoNodes.isNotEmpty,
            warnings,
            availableRuleSets,
            activeRuleSets,
            systemDns,
            editableRules,
          );
    final inbounds = <Map<String, dynamic>>[
      if (!testOnly) _buildMixedInbound(snapshot, target),
      if (!testOnly && useTun) _buildTunInbound(snapshot, target, warnings),
    ];
    final effectiveInbounds =
        !testOnly && snapshot.advancedJson.containsKey('inbounds')
        ? snapshot.advancedJson['inbounds']
        : inbounds;
    // VpnService protects Android sockets when a TUN is active. Without a
    // TUN, Android already routes sockets through the system default network.
    route['auto_detect_interface'] =
        (target == CompileTarget.windows && wireGuard != null) ||
        _hasTunInbound(effectiveInbounds);

    final config = <String, dynamic>{
      'log': testOnly
          ? {'level': 'warn'}
          : {
              'level': settings.advancedOrDefault.logLevel,
              'timestamp': true,
              if (logPath != null && logPath.isNotEmpty) 'output': logPath,
            },
      'dns': dns,
      'inbounds': inbounds,
      'outbounds': outbounds,
      'route': route,
      if (!testOnly)
        'experimental': {
          'cache_file': {'enabled': true, 'path': cachePath},
        },
    };

    if (wireGuard != null) {
      _applyWireGuard(
        wireGuard,
        config,
        dns,
        route,
        outbounds,
        inbounds,
        nodeTags,
        only: wireGuardOnly,
        target: target,
        tunIpv6Enabled: settings.tunOrDefault.ipv6,
        systemDns: systemDns,
      );
      if (wireGuardOnly) editableRules.clear();
    }
    final generatedRules = route['rules'];

    if (!testOnly && snapshot.advancedJson.isNotEmpty) {
      _deepMerge(config, snapshot.advancedJson, warnings);
    }

    _validateDesktopProxy(config, target);
    final violations = ConfigPolicy.validate(config);
    if (violations.isNotEmpty) {
      throw ConfigCompileException(
        '配置包含不支持的设置：${violations.map((e) => e.message).toSet().join('；')}',
        violations: violations,
      );
    }

    final effectiveRoute = config['route'];
    return CompiledConfig(
      json: config,
      encoded: const JsonEncoder.withIndent('  ').convert(config),
      warnings: warnings,
      nodeTags: nodeTags,
      proxyGroupTag: proxyGroupTag,
      autoGroupTag: autoTag,
      custom: false,
      // Advanced JSON can replace the entire rule list, invalidating its indices.
      routeRuleNames:
          effectiveRoute is Map &&
              identical(generatedRules, effectiveRoute['rules'])
          ? Map.unmodifiable({
              for (final entry in editableRules.entries)
                entry.key: entry.value.name,
            })
          : const {},
    );
  }

  /// Builds the route list without needing a connected core or any nodes.
  static RoutingPreview previewRouting(
    AppSnapshot snapshot, {
    required CompileTarget target,
    Map<String, String>? ruleSetPaths,
  }) {
    final editable = <int, RoutingRule>{};
    final Map<String, dynamic> config;
    var overridden = snapshot.useCustomConfig;
    if (snapshot.useCustomConfig) {
      config = _compileCustom(snapshot, target).redactedJson;
    } else {
      final paths =
          ruleSetPaths ?? {for (final tag in builtInRuleSetTags) tag: tag};
      final nodes = snapshot.allNodes.where(
        (node) => _isSupportedOutbound(node.outbound),
      );
      final hasAutoGroup = autoCandidates(
        nodes,
        snapshot.subscriptions,
      ).isNotEmpty;
      final proxyGroup =
          snapshot.settings.selectionMode == SelectionMode.auto && hasAutoGroup
          ? autoTag
          : proxyTag;
      final route = _buildRoute(
        snapshot,
        target == CompileTarget.android
            ? snapshot.settings.vpnEnabled
            : snapshot.settings.tunEnabled,
        proxyGroup,
        hasAutoGroup,
        [],
        paths,
        snapshot.activeRuleSetTags(paths.containsKey),
        null,
        editable,
      );
      final generated = route['rules'];
      config = {'route': route};
      if (snapshot.advancedJson.containsKey('route')) {
        _deepMerge(config, {'route': snapshot.advancedJson['route']}, []);
      }
      final effective = config['route'];
      overridden =
          effective is! Map || !identical(effective['rules'], generated);
      if (overridden) editable.clear();
    }
    final route = config['route'];
    final rules = route is Map ? route['rules'] : null;
    final outbounds = config['outbounds'] ?? snapshot.advancedJson['outbounds'];
    final firstOutbound = outbounds is List && outbounds.firstOrNull is Map
        ? (outbounds.first as Map)['tag']
        : null;
    final fallback = route is Map ? route['final'] : null;
    return RoutingPreview(
      coreRules: [
        if (rules is List)
          for (final (index, rule) in rules.indexed)
            if (rule is Map && !editable.containsKey(index))
              Map<String, dynamic>.from(rule),
      ],
      activeRuleIds: {for (final rule in editable.values) rule.id},
      finalOutbound: fallback is String && fallback.isNotEmpty
          ? fallback
          : firstOutbound is String && firstOutbound.isNotEmpty
          ? firstOutbound
          : snapshot.useCustomConfig
          ? null
          : directTag,
      overridden: overridden,
    );
  }

  static void _applyWireGuard(
    WireGuardConfig profile,
    Map<String, dynamic> config,
    Map<String, dynamic> dns,
    Map<String, dynamic> route,
    List<Map<String, dynamic>> outbounds,
    List<Map<String, dynamic>> inbounds,
    Map<String, String> nodeTags, {
    required bool only,
    required CompileTarget target,
    required bool tunIpv6Enabled,
    required String? systemDns,
  }) {
    final windowsStandalone = only && target == CompileTarget.windows;
    final forwardTunPackets = windowsStandalone && _hasTunInbound(inbounds);
    final restrictUncovered = windowsStandalone && profile.windowsProtection;
    final allowedIps = profile.allowedIps;
    final interfaceAddresses = profile.options['address'] as List<String>;
    final hasIpv4Tunnel =
        interfaceAddresses.any((address) => !address.contains(':')) &&
        allowedIps.any((prefix) => !prefix.contains(':'));
    final hasIpv6Tunnel =
        interfaceAddresses.any((address) => address.contains(':')) &&
        allowedIps.any((prefix) => prefix.contains(':'));
    if (only && !hasIpv4Tunnel && !hasIpv6Tunnel) {
      throw const ConfigCompileException(
        'WireGuard 的 Address 和 AllowedIPs 没有可用的同类地址。',
      );
    }
    // Keep IPv6 for an IPv6-only profile. A dual-stack Android VPN can omit
    // IPv6 when the profile's gateway only provides working IPv4 connectivity.
    final useIpv6ForTun =
        hasIpv6Tunnel &&
        (target != CompileTarget.android || !hasIpv4Tunnel || tunIpv6Enabled);
    final useIpv6ForDns = _hasTunInbound(inbounds)
        ? useIpv6ForTun
        : hasIpv6Tunnel;
    final hasDomainPeer = profile.peers.any(
      (peer) => InternetAddress.tryParse(peer['address'] as String) == null,
    );
    final endpoint = profile.toEndpoint(
      wireGuardTag,
      resolver: hasDomainPeer ? wireGuardBootstrapTag : null,
    );
    if (forwardTunPackets) {
      // Use the core's WireGuard default for both ends of the packet path
      // unless the profile supplies its own MTU.
      endpoint.putIfAbsent('mtu', () => 1408);
    }
    config['endpoints'] = [endpoint];
    final physical = outbounds.first;
    physical['tag'] = physicalTag;
    outbounds.insert(1, {
      'type': 'neko-wireguard-route',
      'tag': directTag,
      'endpoint': wireGuardTag,
      'physical': physicalTag,
      'allowed_ips': allowedIps,
      'resolver': 'dns-direct',
      // Without TUN, restrict proxy dials locally without changing the firewall.
      if (restrictUncovered)
        (forwardTunPackets ? 'protect_windows' : 'block_uncovered'): true,
    });
    for (final outbound in outbounds.skip(2)) {
      if (!nodeTags.containsValue(outbound['tag'])) continue;
      outbound['detour'] = directTag;
      if (outbound['server'] case final String host when _isDomain(host)) {
        outbound['domain_resolver'] = {'server': 'dns-direct'};
      }
    }
    final servers = (dns['servers'] as List).cast<Map<String, dynamic>>();
    servers.removeWhere((server) => server['tag'] == systemTag);
    for (final server in servers.where((server) => server['type'] == 'local')) {
      server['prefer_go'] = true;
      server['detour'] = server['tag'] == 'dns-proxy'
          ? (route['final'] == autoTag ? autoTag : proxyTag)
          : directTag;
    }
    if (hasDomainPeer) {
      servers.add({
        'tag': wireGuardBootstrapTag,
        if (systemDns == null)
          'type': 'local'
        else ...{
          'type': 'udp',
          'server': systemDns,
          'detour': physicalTag,
        },
      });
    }
    if (profile.dns.isNotEmpty || only) {
      servers.removeWhere((server) => server['tag'] == 'dns-direct');
      servers.add(
        profile.dns.isEmpty
            ? {
                'tag': 'dns-direct',
                if (systemDns == null) ...{
                  'type': 'local',
                  'prefer_go': true,
                  'detour': directTag,
                } else ...{
                  'type': 'udp',
                  'server': systemDns,
                  'detour': directTag,
                },
              }
            : {
                'type': 'neko-wireguard-dns',
                'tag': 'dns-direct',
                'servers': profile.dns,
                if (profile.searchDomains.isNotEmpty)
                  'search_domains': profile.searchDomains,
                'detour': directTag,
              },
      );
    }
    route['default_domain_resolver'] = {'server': 'dns-direct'};
    final tunRoutes = [
      for (final prefix in allowedIps)
        if (prefix.contains(':') ? useIpv6ForTun : hasIpv4Tunnel) prefix,
    ];
    for (final inbound in inbounds.where((item) => item['type'] == 'tun')) {
      if (!only) {
        // OS route exclusions act before sing-box sees the packet. Leave WG
        // networks in TUN so the normal rules and AllowedIPs can route them.
        final lanBypass = inbound['route_exclude_address'] as List<String>?;
        if (lanBypass != null) {
          final remaining = subtractRoutePrefixes(lanBypass, allowedIps);
          if (remaining.isEmpty) {
            inbound.remove('route_exclude_address');
          } else {
            inbound['route_exclude_address'] = remaining;
          }
        }
        continue;
      }
      inbound['auto_route'] = true;
      inbound.remove('route_exclude_address');
      final addresses = inbound['address'] as List<String>;
      inbound['route_address'] = tunRoutes;
      if (forwardTunPackets) inbound['mtu'] = endpoint['mtu'];
      if (!useIpv6ForTun) {
        addresses.removeWhere((address) => address.contains(':'));
      } else if (!addresses.any((address) => address.contains(':'))) {
        addresses.add('fdfe:dcba:9876::1/126');
      }
    }
    if (only) {
      servers.removeWhere(
        (server) => !const {
          'dns-direct',
          wireGuardBootstrapTag,
        }.contains(server['tag']),
      );
      dns.remove('rules');
      dns['final'] = 'dns-direct';
      // DNS must not advertise a family which this tunnel cannot carry.
      dns['strategy'] = !useIpv6ForDns
          ? 'ipv4_only'
          : hasIpv4Tunnel
          ? 'prefer_ipv4'
          : 'ipv6_only';
      route
        ..remove('rule_set')
        ..remove('find_process')
        ..['final'] = directTag
        ..['rules'] = [
          {
            'inbound': [wireGuardTag],
            'action': 'reject',
          },
          {'port': 53, 'action': 'hijack-dns'},
          if (forwardTunPackets)
            {
              // Let sing-box forward the original packets to WireGuard.
              // The loopback proxy and DNS still use the dialer below.
              'inbound': [tunTag],
              'ip_cidr': tunRoutes,
              'action': 'route',
              'outbound': wireGuardTag,
            },
        ];
    }
  }

  static CompiledConfig _compileCustom(
    AppSnapshot snapshot,
    CompileTarget target,
  ) {
    final text = snapshot.customConfig.trim();
    if (text.isEmpty) throw const ConfigCompileException('完整自定义配置为空');
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw ConfigCompileException(
        '自定义配置 JSON 格式错误（字符位置 ${error.offset ?? 0}）',
      );
    }
    if (decoded is! Map) {
      throw const ConfigCompileException('自定义配置根节点必须是 JSON 对象');
    }
    final config = Map<String, dynamic>.from(decoded);
    _validateDesktopProxy(config, target);
    final violations = ConfigPolicy.validate(config);
    if (violations.isNotEmpty) {
      throw ConfigCompileException(
        '自定义配置包含被禁止的能力：${violations.map((e) => e.message).toSet().join('；')}',
        violations: violations,
      );
    }
    if (config['outbounds'] is! List) {
      throw const ConfigCompileException('自定义配置必须包含 outbounds');
    }
    return CompiledConfig(
      json: config,
      encoded: const JsonEncoder.withIndent('  ').convert(config),
      warnings: const ['完整自定义配置模式：节点选择由配置本身决定。'],
      nodeTags: const {},
      proxyGroupTag: proxyTag,
      autoGroupTag: autoTag,
      custom: true,
    );
  }

  static void _validateDesktopProxy(
    Map<String, dynamic> config,
    CompileTarget target,
  ) {
    final inbounds = config['inbounds'];
    if (target == CompileTarget.linux &&
        inbounds is List &&
        inbounds.whereType<Map>().any(
          (item) => item['set_system_proxy'] == true,
        )) {
      throw const ConfigCompileException(
        'Linux 系统代理由应用负责恢复，请移除入站的 set_system_proxy 设置并使用首页开关。',
      );
    }
  }

  static bool _isSupportedOutbound(Map<String, dynamic> outbound) {
    final type = outbound['type'];
    if (type is! String) return false;
    return !const {
      'direct',
      'block',
      'selector',
      'urltest',
      'dns',
    }.contains(type);
  }

  // Test-only engines resolve node server names through the system resolver so
  // a proxy protocol's handshake never waits for (or trusts answers from) the
  // user's DoH. Public resolvers can be slow or filtered on some networks,
  // which inflates every latency probe and marks working nodes as failed.
  static Map<String, dynamic> _buildTestDns(
    AppSnapshot snapshot,
    List<String> warnings,
    String? systemDns,
  ) {
    final dns = snapshot.settings.dnsOrDefault;
    return {
      'servers': [
        _bootstrapServer(),
        if (systemDns != null) _systemServer(systemDns),
        _dnsServer(
          tag: 'dns-direct',
          value: dns.directServer,
          detour: directTag,
          resolver: bootstrapTag,
          warnings: warnings,
        ),
      ],
      'final': 'dns-direct',
      'strategy': 'prefer_ipv4',
      'independent_cache': true,
    };
  }

  /// Plain UDP resolver using the device's own network DNS. This is what the
  /// platform (and other proxy clients) use for proxy server addresses; it is
  /// reachable before any DoH connection exists and bypasses the proxy itself.
  static Map<String, dynamic> _systemServer(String address) {
    return {
      'type': 'udp',
      'tag': systemTag,
      'server': address,
      'detour': directTag,
    };
  }

  /// Only plain IPv4 servers are usable as a fixed UDP endpoint; IPv6
  /// link-local entries from LinkProperties cannot be dialed without a scope.
  static String? _systemDnsAddress(List<String> servers) {
    for (final raw in servers) {
      final value = raw.trim();
      final match = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
          .firstMatch(value);
      if (match == null) continue;
      var valid = true;
      for (var i = 1; i <= 4; i++) {
        final octet = int.parse(match.group(i)!);
        if (octet > 255) {
          valid = false;
          break;
        }
      }
      if (valid) return value;
    }
    return null;
  }

  /// Plain UDP resolver at a fixed address. The configured DoH servers are
  /// addressed by hostname, and Android exposes no resolv.conf, so something
  /// has to answer before any DoH connection can be opened.
  static Map<String, dynamic> _bootstrapServer() {
    return {
      'type': 'udp',
      'tag': bootstrapTag,
      'server': DnsSettings.bootstrapServer,
      'detour': directTag,
    };
  }

  static Map<String, dynamic> _buildDns(
    AppSnapshot snapshot,
    CompileTarget target,
    bool useTun,
    String proxyGroupTag,
    List<String> warnings,
    String? systemDns,
    Set<String> activeRuleSets,
  ) {
    final dns = snapshot.settings.dnsOrDefault;
    final mode = snapshot.settings.splitMode;
    final servers = <Map<String, dynamic>>[
      _bootstrapServer(),
      if (systemDns != null) _systemServer(systemDns),
    ];

    final directServer = _dnsServer(
      tag: 'dns-direct',
      value: dns.directServer,
      detour: directTag,
      resolver: bootstrapTag,
      warnings: warnings,
    );
    final proxyServer = _dnsServer(
      tag: 'dns-proxy',
      value: dns.proxyServer,
      detour: proxyGroupTag,
      resolver: 'dns-direct',
      warnings: warnings,
    );
    servers.add(directServer);
    if (dns.proxyServer != dns.directServer) {
      servers.add(proxyServer);
    } else {
      servers.add({...proxyServer, 'tag': 'dns-proxy'});
    }

    final rules = <Map<String, dynamic>>[];
    if (mode == SplitMode.rule &&
        dns.dnsRouting &&
        activeRuleSets.contains('geosite-cn')) {
      rules.add({
        'rule_set': ['geosite-cn'],
        'action': 'route',
        'server': 'dns-direct',
      });
    }

    final finalServer = mode == SplitMode.direct ? 'dns-direct' : 'dns-proxy';
    // Without TUN IPv6, advertising AAAA only sends apps into a dead route.
    final strategy =
        target == CompileTarget.android &&
            useTun &&
            !snapshot.settings.tunOrDefault.ipv6
        ? 'ipv4_only'
        : dns.strategy;
    return {
      'servers': servers,
      'rules': rules,
      'final': finalServer,
      'strategy': strategy,
      'reverse_mapping': dns.reverseMapping,
      'timeout': dns.timeout,
      'independent_cache': true,
      'cache_capacity': 4096,
    };
  }

  static Map<String, dynamic> _dnsServer({
    required String tag,
    required String value,
    required String detour,
    required String resolver,
    required List<String> warnings,
  }) {
    final parsed = _parseDnsEndpoint(value);
    if (parsed == null) {
      warnings.add('DNS 地址无效，已使用本地 DNS：$value');
      return {'type': 'local', 'tag': tag};
    }
    final result = <String, dynamic>{
      'tag': tag,
      'type': parsed.$1,
      if (parsed.$2.isNotEmpty) 'server': parsed.$2,
      if (parsed.$3 != null) 'server_port': parsed.$3,
      if (parsed.$4 != null) 'path': parsed.$4,
      'detour': detour,
    };
    if (_isDomain(parsed.$2) && parsed.$1 != 'local') {
      result['domain_resolver'] = {'server': resolver};
    }
    if (parsed.$1 == 'tls' ||
        parsed.$1 == 'https' ||
        parsed.$1 == 'quic' ||
        parsed.$1 == 'h3') {
      result['tls'] = {
        'enabled': true,
        if (_isDomain(parsed.$2)) 'server_name': parsed.$2,
      };
    }
    return result;
  }

  /// Returns (type, host, port, path).
  static (String, String, int?, String?)? _parseDnsEndpoint(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final lower = trimmed.toLowerCase();
    if (lower == 'local') return ('local', '', null, null);
    if (!lower.contains('://')) {
      final ip = trimmed;
      if (!_looksLikeHost(ip)) return null;
      return ('udp', ip, null, null);
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return null;
    switch (uri.scheme.toLowerCase()) {
      case 'udp':
      case 'tcp':
      case 'tls':
      case 'https':
      case 'quic':
      case 'h3':
        return (
          uri.scheme.toLowerCase(),
          uri.host,
          uri.hasPort ? uri.port : null,
          uri.scheme.toLowerCase() == 'https' ||
                  uri.scheme.toLowerCase() == 'h3'
              ? (uri.path.isEmpty ? '/dns-query' : uri.path)
              : null,
        );
      case 'http':
        return (
          'https',
          uri.host,
          uri.hasPort ? uri.port : 443,
          uri.path.isEmpty ? '/dns-query' : uri.path,
        );
      default:
        return null;
    }
  }

  static Map<String, dynamic> _buildRoute(
    AppSnapshot snapshot,
    bool useTun,
    String proxyGroupTag,
    bool hasAutoGroup,
    List<String> warnings,
    Map<String, String> ruleSetPaths,
    Set<String> activeRuleSets,
    String? systemDns,
    Map<int, RoutingRule> editableRules,
  ) {
    final settings = snapshot.settings;
    final mode = settings.splitMode;
    final rules = <Map<String, dynamic>>[];

    if (snapshot.outboundMode == OutboundMode.wireGuardProxy) {
      rules.add({
        'inbound': [wireGuardTag],
        'action': 'reject',
      });
    }
    if (settings.dnsOrDefault.sniff) {
      rules.add({'action': 'sniff'});
    }
    if (useTun) {
      rules.add({'protocol': 'dns', 'action': 'hijack-dns'});
    }
    if (mode == SplitMode.rule) {
      for (final rule in snapshot.rules) {
        if (!rule.enabled) continue;
        final built = _buildRule(
          rule,
          proxyGroupTag,
          hasAutoGroup,
          warnings,
          activeRuleSets,
        );
        if (built != null) {
          editableRules[rules.length] = rule;
          rules.add(built);
        }
      }
    }

    final needsProcess = snapshot.rules.any(
      (rule) =>
          rule.enabled &&
          rule.effectiveConditions.any(
            (condition) =>
                condition.kind == RuleKind.processName ||
                condition.kind == RuleKind.processPath,
          ),
    );
    final finalOutbound = mode == SplitMode.direct ? directTag : proxyGroupTag;

    return {
      'rules': rules,
      'final': finalOutbound,
      if (needsProcess) 'find_process': true,
      'default_domain_resolver': {
        'server': systemDns == null ? 'dns-direct' : systemTag,
      },
      if (activeRuleSets.isNotEmpty)
        'rule_set': [
          for (final tag in {...builtInRuleSetTags, ...activeRuleSets})
            if (activeRuleSets.contains(tag))
              {
                'type': 'local',
                'tag': tag,
                'format': 'binary',
                'path': ruleSetPaths[tag],
              },
        ],
    };
  }

  static Map<String, dynamic>? _buildRule(
    RoutingRule rule,
    String proxyGroupTag,
    bool hasAutoGroup,
    List<String> warnings,
    Set<String> activeRuleSets,
  ) {
    final Map<String, dynamic> match;
    if (rule.isLogical) {
      final children = <Map<String, dynamic>>[];
      for (final condition in rule.conditions) {
        final child = _buildCondition(
          condition.kind,
          condition.value,
          rule.name,
          warnings,
          activeRuleSets,
        );
        if (child == null) return null;
        children.add(child);
      }
      if (children.length < 2) return null;
      match = {
        'type': 'logical',
        'mode': rule.logic == RuleLogic.and ? 'and' : 'or',
        'rules': children,
      };
    } else {
      final child = _buildCondition(
        rule.kind,
        rule.value,
        rule.name,
        warnings,
        activeRuleSets,
      );
      if (child == null) return null;
      match = child;
    }

    switch (rule.target) {
      case RuleTarget.proxy:
        match['action'] = 'route';
        match['outbound'] = proxyGroupTag;
      case RuleTarget.direct:
        match['action'] = 'route';
        match['outbound'] = directTag;
      case RuleTarget.block:
        match['action'] = 'reject';
      case RuleTarget.manualGroup:
        match['action'] = 'route';
        match['outbound'] = proxyTag;
      case RuleTarget.autoGroup:
        if (hasAutoGroup) {
          match['action'] = 'route';
          match['outbound'] = autoTag;
        } else {
          warnings.add('规则「${rule.name}」指定自动选择，但当前没有启用的自动节点，已改走手动选择。');
          match['action'] = 'route';
          match['outbound'] = proxyTag;
        }
    }
    return match;
  }

  static Map<String, dynamic>? _buildCondition(
    RuleKind kind,
    String rawValue,
    String ruleName,
    List<String> warnings,
    Set<String> activeRuleSets,
  ) {
    final values = kind == RuleKind.ruleSet
        ? splitRuleSetTags(rawValue)
        : splitRuleValues(rawValue);
    if (kind.takesValue && values.isEmpty) {
      warnings.add('规则「$ruleName」的条件为空，已跳过。');
      return null;
    }

    final match = <String, dynamic>{};
    switch (kind) {
      case RuleKind.domain:
        match['domain'] = values;
      case RuleKind.domainSuffix:
        match['domain_suffix'] = values;
      case RuleKind.domainKeyword:
        match['domain_keyword'] = values;
      case RuleKind.domainRegex:
        match['domain_regex'] = values;
      case RuleKind.privateIp:
        match['ip_is_private'] = true;
      case RuleKind.ipCidr:
        match['ip_cidr'] = values;
      case RuleKind.sourceIpCidr:
        match['source_ip_cidr'] = values;
      case RuleKind.port:
        final ports = values.map(int.tryParse).whereType<int>().toList();
        if (ports.isEmpty) return null;
        match['port'] = ports;
      case RuleKind.sourcePort:
        final ports = values.map(int.tryParse).whereType<int>().toList();
        if (ports.isEmpty) return null;
        match['source_port'] = ports;
      case RuleKind.network:
      case RuleKind.protocol:
        match[kind == RuleKind.network ? 'network' : 'protocol'] = values.first
            .toLowerCase();
      case RuleKind.processName:
        match['process_name'] = values;
      case RuleKind.processPath:
        match['process_path'] = values;
      case RuleKind.packageName:
        match['package_name'] = values;
      case RuleKind.ruleSet:
        final known = values.where(activeRuleSets.contains).toList();
        if (known.isEmpty) {
          warnings.add('规则「$ruleName」引用了不存在的规则集，已跳过。');
          return null;
        }
        if (known.length != values.length) {
          warnings.add('规则「$ruleName」包含未知规则集，已自动忽略。');
        }
        match['rule_set'] = known;
    }
    return match;
  }

  static Map<String, dynamic> _buildMixedInbound(
    AppSnapshot snapshot,
    CompileTarget target,
  ) {
    final inbound = snapshot.settings.inboundOrDefault;
    final hasAuth =
        inbound.authUsername.isNotEmpty || inbound.authPassword.isNotEmpty;
    return {
      'type': 'mixed',
      'tag': mixedTag,
      'listen': inbound.allowLan ? '0.0.0.0' : '127.0.0.1',
      'listen_port': inbound.localPort,
      if (hasAuth)
        'users': [
          {'username': inbound.authUsername, 'password': inbound.authPassword},
        ],
    };
  }

  static Map<String, dynamic> _buildTunInbound(
    AppSnapshot snapshot,
    CompileTarget target,
    List<String> warnings,
  ) {
    final tun = snapshot.settings.tunOrDefault;
    var stack = tun.stack.name;
    if (target == CompileTarget.windows && stack != 'system') {
      warnings.add('Windows 仅支持 system TUN 栈，已自动改用 system。');
      stack = 'system';
    }
    return {
      'type': 'tun',
      'tag': tunTag,
      'interface_name': switch (target) {
        CompileTarget.windows => 'NekoProxy',
        CompileTarget.android => 'tun0',
        CompileTarget.linux => 'nekoproxy0',
      },
      if (target == CompileTarget.linux) ...{
        'auto_redirect': false,
        'iproute2_table_index': 20771,
        'iproute2_rule_index': 19771,
      },
      'address': ['172.19.0.1/30', if (tun.ipv6) 'fdfe:dcba:9876::1/126'],
      'mtu': tun.mtu,
      'auto_route': tun.autoRoute,
      'strict_route': tun.strictRoute,
      'stack': stack,
      'dns_mode': 'hijack',
      if (tun.bypassLan)
        'route_exclude_address': [
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '169.254.0.0/16',
          'fc00::/7',
          'fe80::/10',
        ],
    };
  }

  static bool _isDomain(String host) {
    if (host.isEmpty) return false;
    return !RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) &&
        !host.contains(':');
  }

  static bool _looksLikeHost(String value) {
    if (value.isEmpty || value.contains(' ')) return false;
    return _isDomain(value) ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(value);
  }

  static void _deepMerge(
    Map<String, dynamic> target,
    Map<String, dynamic> source,
    List<String> warnings,
  ) {
    for (final entry in source.entries) {
      final existing = target[entry.key];
      if (existing is Map && entry.value is Map) {
        final existingMap = Map<String, dynamic>.from(existing);
        _deepMerge(
          existingMap,
          Map<String, dynamic>.from(entry.value as Map),
          warnings,
        );
        target[entry.key] = existingMap;
      } else {
        if (existing != null) warnings.add('高级 JSON 覆盖了 ${entry.key}');
        target[entry.key] = entry.value;
      }
    }
  }
}
