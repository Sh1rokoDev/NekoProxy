import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/widgets.dart';
import 'package:nekoproxy/domain/models.dart';

void main() {
  group('formatting', () {
    test('formats bytes and speed', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024 * 3), '3.0 MB');
      expect(formatSpeed(2048), '2.0 KB/s');
    });

    test('formats duration and latency', () {
      expect(formatDuration(const Duration(seconds: 42)), '42 秒');
      expect(formatDuration(const Duration(minutes: 7, seconds: 5)), '7 分钟');
      expect(
        formatDuration(const Duration(hours: 2, minutes: 30)),
        '2 小时 30 分',
      );
      expect(formatDuration(const Duration(days: 1, hours: 3)), '1 天 3 小时');
      expect(formatLatency(null), '—');
      expect(formatLatency(0), '<1ms');
      expect(formatLatency(120), '120ms');
      expect(formatLatency(1585), '1.6s');
    });
  });

  group('snapshot serialization', () {
    test('new node collections accept added nodes', () {
      final group = Subscription(id: 'g1', name: 'Group');
      group.nodes.add(
        ProxyNode(
          id: 'n1',
          tag: 'node-n1',
          name: 'Node',
          outbound: const {
            'type': 'trojan',
            'server': 'example.com',
            'server_port': 443,
            'password': 'pw',
          },
        ),
      );
      expect(group.nodes, hasLength(1));
    });

    test('prunes duplicate node ids', () {
      final node = ProxyNode(
        id: 'n1',
        tag: 'node-n1',
        name: 'Tokyo',
        outbound: const {
          'type': 'trojan',
          'server': 'example.com',
          'server_port': 443,
          'password': 'pw',
        },
      );
      final snapshot = AppSnapshot(
        settings: AppSettings(),
        subscriptions: [
          Subscription(id: 's1', name: 'Main', nodes: [node, node]),
        ],
      );
      expect(snapshot.pruneDuplicateNodeIds(), 1);
      expect(snapshot.allNodes, hasLength(1));
    });

    test('round-trips settings, rules, subscriptions and nodes', () {
      final snapshot = AppSnapshot(
        settings: AppSettings(
          theme: ThemePreference.dark,
          splitMode: SplitMode.global,
          selectionMode: SelectionMode.auto,
          systemProxyEnabled: true,
          manualNodeId: 'n1',
          perAppMode: PerAppMode.allow,
          perAppPackages: const ['com.example.browser', 'com.example.chat'],
        ),
        subscriptions: [
          Subscription(
            id: 's1',
            name: 'Main',
            url: 'https://example.com/sub',
            autoEnabled: false,
            nodes: [
              ProxyNode(
                id: 'n1',
                tag: 'node-n1',
                name: 'Tokyo',
                outbound: {
                  'type': 'trojan',
                  'server': 'example.com',
                  'server_port': 443,
                  'password': 'pw',
                },
                autoEnabled: false,
                favorite: true,
              ),
            ],
          ),
        ],
        rules: [
          RoutingRule(
            id: 'r1',
            name: 'Direct corp',
            kind: RuleKind.domainSuffix,
            value: 'corp.example',
            target: RuleTarget.direct,
          ),
        ],
        advancedJson: {
          'log': {'level': 'debug'},
        },
      );
      final restored = AppSnapshot.fromJson(snapshot.toJson());
      expect(restored.settings.theme, ThemePreference.dark);
      expect(restored.settings.splitMode, SplitMode.global);
      expect(restored.settings.selectionMode, SelectionMode.auto);
      expect(restored.settings.systemProxyEnabled, isTrue);
      expect(restored.settings.manualNodeId, 'n1');
      expect(restored.settings.perAppMode, PerAppMode.allow);
      expect(restored.settings.perAppPackages, [
        'com.example.browser',
        'com.example.chat',
      ]);
      expect(restored.subscriptions.single.nodes.single.favorite, isTrue);
      expect(restored.subscriptions.single.nodes.single.autoEnabled, isFalse);
      expect(restored.subscriptions.single.autoEnabled, isFalse);
      final custom = restored.rules.firstWhere((rule) => rule.id == 'r1');
      expect(custom.kind, RuleKind.domainSuffix);
      expect(custom.target, RuleTarget.direct);
      expect(restored.rules, hasLength(1));
      expect((restored.advancedJson['log'] as Map)['level'], 'debug');
    });

    test('logical conditions and built-in ids survive serialization', () {
      final snapshot = AppSnapshot.empty();
      final restored = AppSnapshot.fromJson(snapshot.toJson());
      expect(restored.rules, hasLength(5));
      final quic = restored.rules.firstWhere(
        (rule) => rule.builtInId == 'quic-block',
      );
      expect(quic.id, 'builtin-quic-block');
      expect(quic.logic, RuleLogic.and);
      expect(quic.conditions, hasLength(2));
      expect(quic.conditions.first.kind, RuleKind.port);
      expect(quic.conditions.last.kind, RuleKind.network);
      expect(quic.conditions.last.value, 'udp');
    });

    test('rejects previous and unversioned snapshots', () {
      final data = AppSnapshot.empty().toJson();
      expect(
        () => AppSnapshot.fromJson({...data, 'version': 1}),
        throwsFormatException,
      );
      data.remove('version');
      expect(() => AppSnapshot.fromJson(data), throwsFormatException);
    });

    test('retains explicitly configured DNS, TUN and probe settings', () {
      final snapshot = AppSnapshot.empty();
      snapshot.settings
        ..dns = DnsSettings(
          directServer: 'https://223.5.5.5/dns-query',
          proxyServer: 'https://dns.google/dns-query',
        )
        ..tun = TunSettings(ipv6: true)
        ..advanced = AdvancedSettings(
          urlTestUrl: 'https://www.gstatic.com/generate_204',
          urlTestTolerance: 10,
          interruptExistingConnections: false,
        );
      final settings = AppSnapshot.fromJson(snapshot.toJson()).settings;
      expect(settings.dnsOrDefault.directServer, 'https://223.5.5.5/dns-query');
      expect(settings.dnsOrDefault.proxyServer, 'https://dns.google/dns-query');
      expect(settings.tunOrDefault.ipv6, isTrue);
      expect(
        settings.advancedOrDefault.urlTestUrl,
        'https://www.gstatic.com/generate_204',
      );
      expect(settings.advancedOrDefault.urlTestTolerance, 10);
      expect(settings.advancedOrDefault.interruptExistingConnections, isFalse);
    });

    test('fills missing probe settings with defaults', () {
      final advanced = AppSettings.fromJson({
        'advanced': {'urlTestInterval': '5m'},
      }).advancedOrDefault;

      expect(advanced.urlTestInterval, '5m');
      expect(advanced.urlTestTolerance, 50);
      expect(advanced.interruptExistingConnections, isTrue);
    });

    test('does not reinsert removed rules when loading a saved snapshot', () {
      final snapshot = AppSnapshot.empty()..rules.clear();
      expect(AppSnapshot.fromJson(snapshot.toJson()).rules, isEmpty);
    });

    test('empty snapshot is usable', () {
      final snapshot = AppSnapshot.empty();
      expect(snapshot.allNodes, isEmpty);
      expect(snapshot.nodeById('missing'), isNull);
      expect(
        snapshot.settings.dnsOrDefault.proxyServer,
        DnsSettings.defaultProxyServer,
      );
      expect(snapshot.settings.tunOrDefault.ipv6, isFalse);
      expect(
        snapshot.settings.advancedOrDefault.urlTestUrl,
        'http://www.gstatic.com/generate_204',
      );
      expect(snapshot.settings.advancedOrDefault.urlTestTolerance, 50);
      expect(
        snapshot.settings.advancedOrDefault.interruptExistingConnections,
        isTrue,
      );
      expect(snapshot.rules, hasLength(5));
      expect(snapshot.rules.first.builtInId, 'quic-block');
    });
  });
}
