import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/domain/config_compiler.dart';
import 'package:nekoproxy/domain/config_policy.dart';
import 'package:nekoproxy/domain/models.dart';

ProxyNode node(String id, {bool autoEnabled = true}) {
  return ProxyNode(
    id: id,
    tag: 'node-$id',
    name: 'Node $id',
    autoEnabled: autoEnabled,
    outbound: {
      'type': 'shadowsocks',
      'server': '$id.example.com',
      'server_port': 8388,
      'method': 'aes-128-gcm',
      'password': 'secret-$id',
    },
  );
}

AppSnapshot snapshotWith(List<ProxyNode> nodes) {
  return AppSnapshot.empty()
    ..settings.manualNodeId = nodes.isEmpty ? null : nodes.first.id
    ..subscriptions.add(Subscription(id: 'sub', name: 'Main', nodes: nodes));
}

void main() {
  group('ConfigCompiler managed mode', () {
    test('builds real-IP DNS, selector, urltest and node outbounds', () {
      final snapshot = snapshotWith([node('a'), node('b', autoEnabled: false)]);
      snapshot.settings.dnsOrDefault.directServer =
          'https://dns.alidns.com/dns-query';
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.windows,
        cachePath: 'C:/tmp/cache.db',
        logPath: 'C:/tmp/core.log',
      );
      final json = compiled.json;
      expect(compiled.custom, isFalse);
      expect(compiled.nodeTags.keys, containsAll(['a', 'b']));

      final dns = json['dns'] as Map<String, dynamic>;
      final servers = (dns['servers'] as List).cast<Map>();
      expect(servers.any((server) => server['type'] == 'fakeip'), isFalse);
      expect(
        servers.map((server) => server['tag']),
        containsAll(['dns-bootstrap', 'dns-direct', 'dns-proxy']),
      );
      expect(dns['reverse_mapping'], isTrue);
      final bootstrap = servers.firstWhere(
        (server) => server['tag'] == 'dns-bootstrap',
      );
      expect(bootstrap['type'], 'udp');
      expect(bootstrap['server'], DnsSettings.bootstrapServer);
      expect(bootstrap['detour'], 'direct');
      final directDns = servers.firstWhere(
        (server) => server['tag'] == 'dns-direct',
      );
      expect(directDns['domain_resolver'], {'server': 'dns-bootstrap'});
      final proxyDns = servers.firstWhere(
        (server) => server['tag'] == 'dns-proxy',
      );
      expect(proxyDns['domain_resolver'], {'server': 'dns-direct'});
      expect(proxyDns['detour'], compiled.proxyGroupTag);
      expect(proxyDns['tls'], {
        'enabled': true,
        'server_name': 'dns.cloudflare.com',
      });
      expect(dns['independent_cache'], isTrue);

      final outbounds = (json['outbounds'] as List).cast<Map>();
      final selector = outbounds.firstWhere(
        (item) => item['type'] == 'selector',
      );
      expect(selector['tag'], 'proxy');
      expect(selector['outbounds'], [
        compiled.nodeTags['a'],
        compiled.nodeTags['b'],
      ]);
      final urltest = outbounds.firstWhere((item) => item['type'] == 'urltest');
      expect(urltest['outbounds'], [compiled.nodeTags['a']]);
      expect(urltest['url'], 'http://www.gstatic.com/generate_204');
      expect(urltest['interval'], '3m');
      expect(urltest['tolerance'], 50);
      expect(urltest['idle_timeout'], '30m');
      expect(urltest['interrupt_exist_connections'], isTrue);
      expect(json['log']['level'], 'info');

      final nodeOutbound = outbounds.firstWhere(
        (item) => item['tag'] == compiled.nodeTags['a'],
      );
      expect(nodeOutbound['server'], 'a.example.com');
      expect(nodeOutbound['password'], 'secret-a');

      final route = json['route'] as Map<String, dynamic>;
      expect(route['final'], 'proxy');
      expect(route['auto_detect_interface'], isFalse);
      final ruleSets = (route['rule_set'] as List).cast<Map>();
      expect(ruleSets, hasLength(2));
      expect(ruleSets.every((item) => item['type'] == 'local'), isTrue);
      expect(ruleSets.first['path'], endsWith('rules/geosite-cn.srs'));
      expect(json['experimental'], isNotNull);
    });

    test('uses installed GeoSite attributes and GeoIP categories in rules', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.rules
        ..clear()
        ..add(
          RoutingRule(
            id: 'catalog',
            name: 'GeoSite or GeoIP',
            kind: RuleKind.ruleSet,
            value: 'geosite:Google@Ads',
            target: RuleTarget.direct,
            logic: RuleLogic.or,
            conditions: [
              RuleCondition(
                kind: RuleKind.ruleSet,
                value: 'geosite:Google@Ads',
              ),
              RuleCondition(kind: RuleKind.ruleSet, value: 'geoip:US'),
            ],
          ),
        );
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/runtime/cache.db',
        ruleSetPaths: const {
          'geosite-google@ads': '/runtime/rules/current/geosite-google@ads.srs',
          'geoip-us': '/runtime/rules/current/geoip-us.srs',
          'geoip-jp': '/runtime/rules/current/geoip-jp.srs',
        },
      );

      final route = compiled.json['route'] as Map;
      final rules = (route['rules'] as List).cast<Map>();
      final logical = rules.singleWhere((rule) => rule['type'] == 'logical');
      expect(logical['rules'], [
        {
          'rule_set': ['geosite-google@ads'],
        },
        {
          'rule_set': ['geoip-us'],
        },
      ]);
      final sets = (route['rule_set'] as List).cast<Map>();
      expect(sets.map((set) => set['tag']), ['geosite-google@ads', 'geoip-us']);
      expect(sets.last['path'], '/runtime/rules/current/geoip-us.srs');
    });

    test('automatic selection routes through the native urltest group', () {
      final snapshot = snapshotWith([node('a'), node('b')]);
      snapshot.settings.selectionMode = SelectionMode.auto;
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final route = compiled.json['route'] as Map<String, dynamic>;
      expect(route['final'], 'auto');
      expect(compiled.proxyGroupTag, 'auto');
    });

    test(
      'automatic selection without candidates falls back with a warning',
      () {
        final snapshot = snapshotWith([node('a', autoEnabled: false)]);
        snapshot.settings.selectionMode = SelectionMode.auto;
        final compiled = ConfigCompiler.compile(
          snapshot,
          target: CompileTarget.android,
          cachePath: '/tmp/cache.db',
        );
        expect(compiled.proxyGroupTag, 'proxy');
        expect(
          compiled.warnings.any((warning) => warning.contains('自动选择')),
          isTrue,
        );
      },
    );

    test('automatic selection starts from the last manual node', () {
      final snapshot = snapshotWith([node('a'), node('b'), node('c')]);
      snapshot.settings.manualNodeId = 'c';
      snapshot.settings.selectionMode = SelectionMode.auto;
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final outbounds = (compiled.json['outbounds'] as List).cast<Map>();
      final urltest = outbounds.firstWhere((item) => item['type'] == 'urltest');
      expect(urltest['outbounds'], [
        compiled.nodeTags['c'],
        compiled.nodeTags['a'],
        compiled.nodeTags['b'],
      ]);
    });

    test('excludes disabled groups from automatic candidates', () {
      final snapshot = AppSnapshot(
        settings: AppSettings(manualNodeId: 'a'),
        rules: AppSnapshot.empty().rules,
        subscriptions: [
          Subscription(
            id: 'main',
            name: 'Main',
            nodes: [node('a').copyWith(subscriptionId: 'main')],
          ),
          Subscription(
            id: 'other',
            name: 'Other',
            nodes: [node('b').copyWith(subscriptionId: 'other')],
          ),
        ],
      );
      snapshot.subscriptions.first.autoEnabled = false;
      snapshot.settings.selectionMode = SelectionMode.auto;
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final outbounds = (compiled.json['outbounds'] as List).cast<Map>();
      final urltest = outbounds.firstWhere((item) => item['type'] == 'urltest');
      expect(urltest['outbounds'], [compiled.nodeTags['b']]);
      expect(compiled.proxyGroupTag, 'auto');
    });

    test('maps user rules in order and honours disabled rules', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.rules = [
        RoutingRule(
          id: 'r1',
          name: 'Corp',
          kind: RuleKind.domainSuffix,
          value: 'corp.example\ninternal.example',
          target: RuleTarget.direct,
        ),
        RoutingRule(
          id: 'r2',
          name: 'Disabled',
          kind: RuleKind.domain,
          value: 'ignored.example',
          target: RuleTarget.proxy,
          enabled: false,
        ),
      ];
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.windows,
        cachePath: 'C:/tmp/cache.db',
      );
      final rules = ((compiled.json['route'] as Map)['rules'] as List)
          .cast<Map>();
      final corp = rules.singleWhere((rule) => rule['domain_suffix'] != null);
      expect(corp['domain_suffix'], ['corp.example', 'internal.example']);
      expect(corp['outbound'], 'direct');
      expect(rules.any((rule) => rule['domain'] != null), isFalse);
    });

    test(
      'maps Android package name rules without enabling desktop process lookup',
      () {
        final snapshot = snapshotWith([node('a')]);
        snapshot.rules = [
          RoutingRule(
            id: 'r1',
            name: 'Apps',
            kind: RuleKind.packageName,
            value: 'com.example.app\norg.telegram.messenger',
            target: RuleTarget.proxy,
          ),
        ];
        final compiled = ConfigCompiler.compile(
          snapshot,
          target: CompileTarget.android,
          cachePath: '/tmp/cache.db',
        );
        final route = compiled.json['route'] as Map<String, dynamic>;
        final rules = (route['rules'] as List).cast<Map>();
        final match = rules.singleWhere((rule) => rule['package_name'] != null);
        expect(match['package_name'], [
          'com.example.app',
          'org.telegram.messenger',
        ]);
        expect(route.containsKey('find_process'), isFalse);
      },
    );

    test('built-in rule sets can be selected independently', () {
      final snapshot = snapshotWith([node('a')]);
      for (final rule in snapshot.rules) {
        rule.enabled = false;
      }
      snapshot.rules
              .firstWhere((rule) => rule.value == 'geosite-category-ads-all')
              .enabled =
          true;
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final route = compiled.json['route'] as Map<String, dynamic>;
      final ruleSets = (route['rule_set'] as List).cast<Map>();
      expect(ruleSets.map((item) => item['tag']), ['geosite-category-ads-all']);
      expect(compiled.localRuleSetPaths, [
        '/tmp/rules/geosite-category-ads-all.srs',
      ]);
      final rules = (route['rules'] as List).cast<Map>();
      final ads = rules.singleWhere((rule) => rule['rule_set'] != null);
      expect(ads['rule_set'], ['geosite-category-ads-all']);
      expect(ads['action'], 'reject');
      expect(
        rules.any(
          (rule) =>
              rule['rule_set']?.toString().contains('geosite-cn') ?? false,
        ),
        isFalse,
      );
    });

    test('disabling all rules leaves only direct routing', () {
      final snapshot = snapshotWith([node('a')]);
      for (final rule in snapshot.rules) {
        rule.enabled = false;
      }
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final route = compiled.json['route'] as Map<String, dynamic>;
      expect(route.containsKey('rule_set'), isFalse);
      expect(compiled.localRuleSetPaths, isEmpty);
      final rules = (route['rules'] as List).cast<Map>();
      expect(rules.any((rule) => rule['rule_set'] != null), isFalse);
    });

    test('built-in rules are editable and compile with their own target', () {
      final snapshot = snapshotWith([node('a')]);
      final cnDomain = snapshot.rules.firstWhere(
        (rule) => rule.value == 'geosite-cn',
      );
      cnDomain.target = RuleTarget.proxy;
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final route = compiled.json['route'] as Map<String, dynamic>;
      final rules = (route['rules'] as List).cast<Map>();
      final cn = rules.singleWhere(
        (rule) => (rule['rule_set'] as List?)?.contains('geosite-cn') ?? false,
      );
      expect(cn['action'], 'route');
      expect(cn['outbound'], compiled.proxyGroupTag);
      expect(compiled.routeRuleNames[rules.indexOf(cn)], cnDomain.name);

      snapshot.advancedJson = {
        'route': {
          'rules': [
            {'domain': 'example.com', 'action': 'route', 'outbound': 'direct'},
          ],
        },
      };
      final overridden = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      expect(overridden.routeRuleNames, isEmpty);
    });

    test('unknown rule sets are skipped with a warning', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.rules.add(
        RoutingRule(
          id: 'unknown-set',
          name: 'Custom set',
          kind: RuleKind.ruleSet,
          value: 'custom-set',
          target: RuleTarget.proxy,
        ),
      );
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final route = compiled.json['route'] as Map<String, dynamic>;
      final rules = (route['rules'] as List).cast<Map>();
      expect(
        rules.any((rule) => rule['rule_set']?.contains('custom-set') ?? false),
        isFalse,
      );
      expect(
        compiled.warnings.any((warning) => warning.contains('规则集')),
        isTrue,
      );
    });

    test('seeds five built-in rules in display order', () {
      final snapshot = snapshotWith([node('a')]);
      expect(snapshot.rules.map((rule) => rule.name).toList(), [
        '屏蔽 QUIC',
        '广告与追踪域名',
        '中国 Play 商店规则',
        '中国大陆域名',
        '中国大陆 IP',
      ]);
      final quic = snapshot.rules.first;
      expect(quic.isLogical, isTrue);
      expect(quic.logic, RuleLogic.and);
      expect(quic.target, RuleTarget.block);
      expect(quic.builtInId, 'quic-block');
      expect(quic.conditions.map((item) => item.kind), [
        RuleKind.port,
        RuleKind.network,
      ]);
      expect(snapshot.rules[1].enabled, isFalse);
      expect(snapshot.rules[2].value, 'googleapis.cn');
      expect(snapshot.rules[2].target, RuleTarget.proxy);
    });

    test('built-in logical QUIC and Play rules compile natively', () {
      final snapshot = snapshotWith([node('a')]);
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final rules = ((compiled.json['route'] as Map)['rules'] as List)
          .cast<Map>();
      final quic = rules.singleWhere((rule) => rule['type'] == 'logical');
      expect(quic['mode'], 'and');
      expect(quic['action'], 'reject');
      final children = (quic['rules'] as List).cast<Map>();
      expect(
        children.any(
          (child) => (child['port'] as List?)?.contains(443) ?? false,
        ),
        isTrue,
      );
      expect(children.any((child) => child['network'] == 'udp'), isTrue);
      final play = rules.singleWhere(
        (rule) =>
            (rule['domain_suffix'] as List?)?.contains('googleapis.cn') ??
            false,
      );
      expect(play['outbound'], compiled.proxyGroupTag);
    });

    test('logical rules compile AND/OR children', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.rules.add(
        RoutingRule(
          id: 'custom-logical',
          name: 'Custom logical',
          kind: RuleKind.domainSuffix,
          value: 'example.com',
          target: RuleTarget.block,
          logic: RuleLogic.or,
          conditions: const [
            RuleCondition(kind: RuleKind.domainSuffix, value: 'example.com'),
            RuleCondition(kind: RuleKind.ipCidr, value: '203.0.113.0/24'),
          ],
        ),
      );
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final rules = ((compiled.json['route'] as Map)['rules'] as List)
          .cast<Map>();
      final logical = rules.singleWhere((rule) => rule['mode'] == 'or');
      expect(logical['type'], 'logical');
      expect(logical['action'], 'reject');
      final children = (logical['rules'] as List).cast<Map>();
      expect(
        children.any(
          (child) =>
              (child['domain_suffix'] as List?)?.contains('example.com') ??
              false,
        ),
        isTrue,
      );
      expect(
        children.any(
          (child) =>
              (child['ip_cidr'] as List?)?.contains('203.0.113.0/24') ?? false,
        ),
        isTrue,
      );
    });

    test('rule sets inside logical rules activate SRS and DNS split', () {
      final snapshot = snapshotWith([node('a')]);
      for (final rule in snapshot.rules) {
        rule.enabled = false;
      }
      snapshot.rules.add(
        RoutingRule(
          id: 'logical-cn',
          name: 'Logical CN',
          kind: RuleKind.domainSuffix,
          value: '',
          target: RuleTarget.proxy,
          logic: RuleLogic.or,
          conditions: const [
            RuleCondition(kind: RuleKind.ruleSet, value: 'geosite-cn'),
            RuleCondition(kind: RuleKind.domainSuffix, value: 'example.org'),
          ],
        ),
      );
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final route = compiled.json['route'] as Map<String, dynamic>;
      final ruleSets = (route['rule_set'] as List).cast<Map>();
      expect(ruleSets.map((item) => item['tag']), contains('geosite-cn'));
      final logical = ((route['rules'] as List).cast<Map>()).singleWhere(
        (rule) => rule['type'] == 'logical',
      );
      expect((logical['rules'] as List).cast<Map>().first['rule_set'], [
        'geosite-cn',
      ]);
      final dnsRules = ((compiled.json['dns'] as Map)['rules'] as List)
          .cast<Map>();
      expect(
        dnsRules.any(
          (rule) =>
              (rule['rule_set'] as List?)?.contains('geosite-cn') ?? false,
        ),
        isTrue,
      );
    });

    test('invalid logical conditions skip the whole rule', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.rules.add(
        RoutingRule(
          id: 'logical-invalid',
          name: 'Broken logical',
          kind: RuleKind.ruleSet,
          value: 'missing-set',
          target: RuleTarget.proxy,
          logic: RuleLogic.and,
          conditions: const [
            RuleCondition(kind: RuleKind.ruleSet, value: 'missing-set'),
            RuleCondition(kind: RuleKind.domainSuffix, value: 'example.org'),
          ],
        ),
      );
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final rules = ((compiled.json['route'] as Map)['rules'] as List)
          .cast<Map>();
      expect(
        rules.any(
          (rule) =>
              (rule['domain_suffix'] as List?)?.contains('example.org') ??
              false,
        ),
        isFalse,
      );
      expect(
        compiled.warnings.any((warning) => warning.contains('不存在的规则集')),
        isTrue,
      );
    });

    test('DNS split follows the enabled geosite-cn rule', () {
      final snapshot = snapshotWith([node('a')]);
      for (final rule in snapshot.rules) {
        rule.enabled = false;
      }
      var compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      var dnsRules = ((compiled.json['dns'] as Map)['rules'] as List)
          .cast<Map>();
      expect(
        dnsRules.any(
          (rule) =>
              (rule['rule_set'] as List?)?.contains('geosite-cn') ?? false,
        ),
        isFalse,
      );

      snapshot.rules.firstWhere((rule) => rule.value == 'geosite-cn').enabled =
          true;
      expect(snapshot.hasEnabledRuleSet('geosite-cn'), isTrue);
      expect(snapshot.settings.dnsOrDefault.dnsRouting, isTrue);
      expect(snapshot.settings.splitMode, SplitMode.rule);
      compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      dnsRules = ((compiled.json['dns'] as Map)['rules'] as List).cast<Map>();
      expect(
        dnsRules.any(
          (rule) =>
              (rule['rule_set'] as List?)?.contains('geosite-cn') ?? false,
        ),
        isTrue,
      );
    });

    test('global mode ignores the rule list', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.settings.splitMode = SplitMode.global;
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final route = compiled.json['route'] as Map<String, dynamic>;
      final rules = (route['rules'] as List).cast<Map>();
      expect(rules.any((rule) => rule['rule_set'] != null), isFalse);
      expect(route['final'], compiled.proxyGroupTag);
    });

    test('Windows system proxy leaves interface selection to Windows', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.settings.systemProxyEnabled = true;
      snapshot.settings.tunEnabled = false;

      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.windows,
        cachePath: 'C:/tmp/cache.db',
      );

      expect(compiled.hasTunInbound, isFalse);
      final route = compiled.json['route'] as Map;
      expect(route['auto_detect_interface'], isFalse);
      expect(route, isNot(contains('default_interface')));
    });

    test(
      'uses the system TUN stack on Windows regardless of requested stack',
      () {
        final snapshot = snapshotWith([node('a')]);
        snapshot.settings.tunEnabled = true;
        snapshot.settings.tunOrDefault.stack = StackMode.gvisor;
        final compiled = ConfigCompiler.compile(
          snapshot,
          target: CompileTarget.windows,
          cachePath: 'C:/tmp/cache.db',
        );
        final inbounds = (compiled.json['inbounds'] as List).cast<Map>();
        final tun = inbounds.firstWhere((item) => item['type'] == 'tun');
        expect(tun['stack'], 'system');
        expect(tun['interface_name'], 'NekoProxy');
        expect(compiled.json['route']['auto_detect_interface'], isTrue);
        expect(
          compiled.warnings.any((warning) => warning.contains('TUN')),
          isTrue,
        );
      },
    );

    test('Android always includes the VPN TUN inbound', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.settings.tunEnabled = false;
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );
      final inbounds = (compiled.json['inbounds'] as List).cast<Map>();
      final tun = inbounds.firstWhere((item) => item['type'] == 'tun');
      expect(inbounds.any((item) => item['type'] == 'tun'), isTrue);
      expect(tun['address'], ['172.19.0.1/30']);
      expect((compiled.json['dns'] as Map)['strategy'], 'ipv4_only');
      expect(compiled.json['route']['auto_detect_interface'], isTrue);
      final rules = ((compiled.json['route'] as Map)['rules'] as List)
          .cast<Map>();
      expect(rules.any((rule) => rule['action'] == 'hijack-dns'), isTrue);
    });

    test('mixed inbound stays on loopback unless LAN sharing is enabled', () {
      final snapshot = snapshotWith([node('a')]);
      var compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.windows,
        cachePath: 'C:/tmp/cache.db',
      );
      var mixed = ((compiled.json['inbounds'] as List).cast<Map>()).firstWhere(
        (item) => item['type'] == 'mixed',
      );
      expect(mixed['listen'], '127.0.0.1');
      expect(mixed['listen_port'], 2080);

      snapshot.settings.inboundOrDefault.allowLan = true;
      snapshot.settings.inboundOrDefault.authUsername = 'user';
      snapshot.settings.inboundOrDefault.authPassword = 'pass';
      compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.windows,
        cachePath: 'C:/tmp/cache.db',
      );
      mixed = ((compiled.json['inbounds'] as List).cast<Map>()).firstWhere(
        (item) => item['type'] == 'mixed',
      );
      expect(mixed['listen'], '0.0.0.0');
      expect((mixed['users'] as List).single, {
        'username': 'user',
        'password': 'pass',
      });
    });
  });

  group('ConfigCompiler boundaries', () {
    test('keeps loop protection for a Windows TUN added by JSON', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.settings.tunEnabled = false;
      snapshot.advancedJson = {
        'inbounds': [
          {'type': 'tun', 'tag': 'custom-tun', 'auto_route': true},
        ],
      };

      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.windows,
        cachePath: 'C:/tmp/cache.db',
      );

      expect(compiled.hasTunInbound, isTrue);
      expect(compiled.json['route']['auto_detect_interface'], isTrue);
    });

    test('reads local rule set paths from the final custom configuration', () {
      final snapshot = snapshotWith([node('a')])
        ..useCustomConfig = true
        ..customConfig = jsonEncode({
          'outbounds': [
            {'type': 'direct', 'tag': 'direct'},
          ],
          'route': {
            'rule_set': [
              {
                'type': 'local',
                'tag': 'custom',
                'format': 'binary',
                'path': '/tmp/rules/geoip-us.srs',
              },
              {'type': 'remote', 'tag': 'remote', 'format': 'binary'},
            ],
          },
        });

      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
      );

      expect(compiled.localRuleSetPaths, ['/tmp/rules/geoip-us.srs']);
    });

    test('rejects FakeIP through advanced JSON merge', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.advancedJson = {
        'dns': {
          'servers': [
            {'type': 'fakeip', 'tag': 'fakeip-inbound'},
          ],
        },
      };
      expect(
        () => ConfigCompiler.compile(
          snapshot,
          target: CompileTarget.windows,
          cachePath: 'cache.db',
        ),
        throwsA(
          predicate(
            (e) => e is ConfigCompileException && e.violations.isNotEmpty,
          ),
        ),
      );
    });

    test('rejects Clash API through advanced JSON merge', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.advancedJson = {
        'experimental': {
          'clash_api': {'external_controller': '127.0.0.1:9090'},
        },
      };
      expect(
        () => ConfigCompiler.compile(
          snapshot,
          target: CompileTarget.windows,
          cachePath: 'cache.db',
        ),
        throwsA(isA<ConfigCompileException>()),
      );
    });

    test('rejects an empty node list', () {
      final snapshot = snapshotWith([]);
      expect(
        () => ConfigCompiler.compile(
          snapshot,
          target: CompileTarget.android,
          cachePath: 'cache.db',
        ),
        throwsA(isA<ConfigCompileException>()),
      );
    });

    test('custom configuration is decoded and policy-checked', () {
      final snapshot = AppSnapshot(
        settings: AppSettings(),
        subscriptions: [],
        useCustomConfig: true,
        customConfig: jsonEncode({
          'outbounds': [
            {'type': 'direct', 'tag': 'direct'},
          ],
        }),
      );
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.windows,
        cachePath: 'cache.db',
      );
      expect(compiled.custom, isTrue);
      expect(compiled.warnings.single, contains('完整自定义配置'));

      snapshot.customConfig = jsonEncode({
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'dns': {
          'servers': [
            {'type': 'fakeip', 'tag': 'fakeip'},
          ],
        },
      });
      expect(
        () => ConfigCompiler.compile(
          snapshot,
          target: CompileTarget.windows,
          cachePath: 'cache.db',
        ),
        throwsA(isA<ConfigCompileException>()),
      );
    });

    test('compiled configuration passes policy validation', () {
      final snapshot = snapshotWith([node('a')]);
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: 'cache.db',
      );
      expect(ConfigPolicy.validate(compiled.json), isEmpty);
    });
  });

  group('ConfigCompiler test-only mode', () {
    test('Windows offline probes follow Windows even with TUN configured', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.settings.tunEnabled = true;

      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.windows,
        cachePath: 'C:/tmp/cache.db',
        testOnly: true,
      );

      expect(compiled.hasTunInbound, isFalse);
      expect(compiled.json['route']['auto_detect_interface'], isFalse);
    });

    test('omits TUN, inbounds, rules and urltest probes', () {
      final snapshot = snapshotWith([node('a'), node('b')]);
      snapshot.settings.tunEnabled = true;
      snapshot.settings.selectionMode = SelectionMode.auto;
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
        testOnly: true,
      );

      expect(compiled.hasTunInbound, isFalse);
      expect(compiled.json['inbounds'], isEmpty);
      expect(compiled.json.containsKey('experimental'), isFalse);
      expect(compiled.nodeTags.keys, containsAll(['a', 'b']));

      final outbounds = (compiled.json['outbounds'] as List).cast<Map>();
      expect(outbounds.any((item) => item['type'] == 'tun'), isFalse);
      expect(outbounds.any((item) => item['type'] == 'urltest'), isFalse);
      final selector = outbounds.firstWhere(
        (item) => item['type'] == 'selector',
      );
      expect(selector['outbounds'], [
        compiled.nodeTags['a'],
        compiled.nodeTags['b'],
      ]);

      final route = compiled.json['route'] as Map<String, dynamic>;
      expect(route['final'], 'proxy');
      expect(route['auto_detect_interface'], isTrue);
      expect(route['default_domain_resolver'], {'server': 'dns-direct'});
      expect(route['rules'], isNull);
      expect(route['rule_set'], isNull);

      final dns = compiled.json['dns'] as Map<String, dynamic>;
      expect(dns['final'], 'dns-direct');
      final dnsServers = (dns['servers'] as List).cast<Map>();
      expect(dnsServers.map((server) => server['tag']), [
        'dns-bootstrap',
        'dns-direct',
      ]);
      expect(dnsServers.last['type'], 'https');
      expect(dnsServers.last['server'], 'dns.alidns.com');
      expect(ConfigPolicy.validate(compiled.json), isEmpty);
    });

    test('resolves node server names through the platform DNS', () {
      final snapshot = snapshotWith([node('a')]);
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
        testOnly: true,
        systemDnsServers: const ['10.2.2.1', 'fe80::1'],
      );

      final dns = compiled.json['dns'] as Map<String, dynamic>;
      final system = (dns['servers'] as List).cast<Map>().firstWhere(
            (server) => server['tag'] == 'dns-system',
          );
      expect(system['type'], 'udp');
      expect(system['server'], '10.2.2.1');
      expect(system['detour'], 'direct');
      expect(
        (compiled.json['route'] as Map)['default_domain_resolver'],
        {'server': 'dns-system'},
      );

      final full = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
        systemDnsServers: const ['10.2.2.1'],
      );
      final route = full.json['route'] as Map<String, dynamic>;
      expect(route['default_domain_resolver'], {'server': 'dns-system'});
      expect(
        (full.json['dns'] as Map)['servers'],
        contains(
          containsPair('tag', 'dns-system'),
        ),
      );
    });

    test('falls back to the configured DNS without a platform resolver', () {
      final snapshot = snapshotWith([node('a')]);
      final compiled = ConfigCompiler.compile(
        snapshot,
        target: CompileTarget.android,
        cachePath: '/tmp/cache.db',
        systemDnsServers: const ['fe80::1', 'not-an-ip'],
      );
      expect(
        (compiled.json['route'] as Map)['default_domain_resolver'],
        {'server': 'dns-direct'},
      );
      final tags = (compiled.json['dns'] as Map)['servers'] as List;
      expect(
        tags.map((server) => (server as Map)['tag']),
        isNot(contains('dns-system')),
      );
    });

    test('custom configuration cannot be mapped to node tags offline', () {
      final snapshot = snapshotWith([node('a')]);
      snapshot.useCustomConfig = true;
      snapshot.customConfig = jsonEncode({
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      });
      expect(
        () => ConfigCompiler.compile(
          snapshot,
          target: CompileTarget.android,
          cachePath: '/tmp/cache.db',
          testOnly: true,
        ),
        throwsA(isA<ConfigCompileException>()),
      );
    });
  });

  group('ConfigPolicy structure matching', () {
    test('does not flag ordinary strings that contain forbidden names', () {
      final violations = ConfigPolicy.validateText(
        jsonEncode({
          'outbounds': [
            {
              'type': 'shadowsocks',
              'tag': 'node-fakeip-clash',
              'server': 'example.com',
              'server_port': 8388,
              'method': 'aes-128-gcm',
              'password': 'clash_mode-fakeip',
            },
          ],
        }),
      );
      expect(violations, isEmpty);
    });

    test('finds nested forbidden keys and legacy DNS formats', () {
      final violations = ConfigPolicy.validateText(
        jsonEncode({
          'experimental': {
            'clash_api': {'external_controller': '127.0.0.1:9090'},
          },
          'dns': {
            'servers': [
              {'address': 'https://1.1.1.1/dns-query'},
              {'type': 'fakeip', 'tag': 'fake'},
            ],
          },
        }),
      );
      expect(violations, hasLength(3));
    });
  });
}
