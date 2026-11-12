import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/domain/node_view.dart';

ProxyNode node(
  String id,
  String name, {
  String server = 'example.com',
  String protocol = 'vless',
  bool favorite = false,
}) {
  return ProxyNode(
    id: id,
    tag: id,
    name: name,
    outbound: {'type': protocol, 'server': server, 'server_port': 443},
    favorite: favorite,
  );
}

void main() {
  group('node filters', () {
    test('include and exclude match name, server and protocol', () {
      final nodes = [
        node('a', '香港 01', server: 'hk.example.com'),
        node('b', '日本 01', server: 'jp.example.com'),
        node('c', '剩余流量：10 GB', server: 'info.example.com', protocol: 'trojan'),
      ];
      final visible = applyNodeView(
        nodes: nodes,
        includeFilter: '香港, jp.example.com',
        excludeFilter: '剩余',
      );
      expect(visible.map((item) => item.id), ['a', 'b']);
      expect(
        nodeMatchesFilter(
          nodes[2],
          includeFilter: '',
          excludeFilter: 'info.example.com',
        ),
        isFalse,
      );
      expect(
        nodeMatchesFilter(nodes[0], includeFilter: 'VLESS', excludeFilter: ''),
        isTrue,
      );
    });

    test('empty filters keep every node', () {
      final nodes = [node('a', 'A'), node('b', 'B')];
      expect(applyNodeView(nodes: nodes).length, 2);
    });
  });

  group('node sorting', () {
    test('sorts by name, protocol and favorites', () {
      final nodes = [
        node('a', 'Zulu', protocol: 'trojan'),
        node('b', 'Alpha', protocol: 'vless'),
        node('c', 'Bravo', protocol: 'vmess', favorite: true),
      ];
      expect(
        sortNodeList(
          nodes,
          mode: NodeSortMode.name,
          descending: false,
        ).map((item) => item.name),
        ['Alpha', 'Bravo', 'Zulu'],
      );
      expect(
        sortNodeList(
          nodes,
          mode: NodeSortMode.protocol,
          descending: false,
        ).map((item) => item.protocol),
        ['trojan', 'vless', 'vmess'],
      );
      expect(
        sortNodeList(
          nodes,
          mode: NodeSortMode.favorite,
          descending: false,
        ).first.id,
        'c',
      );
    });

    test('sorts by latency and keeps unmeasured nodes last', () {
      final nodes = [node('a', 'A'), node('b', 'B'), node('c', 'C')];
      final latencies = {'a': 300, 'b': 80};
      expect(
        sortNodeList(
          nodes,
          mode: NodeSortMode.latency,
          descending: false,
          latencies: latencies,
        ).map((item) => item.id),
        ['b', 'a', 'c'],
      );
      expect(
        sortNodeList(
          nodes,
          mode: NodeSortMode.latency,
          descending: true,
          latencies: latencies,
        ).map((item) => item.id),
        ['a', 'b', 'c'],
      );
    });

    test('manual mode reverses only when descending', () {
      final nodes = [node('a', 'A'), node('b', 'B'), node('c', 'C')];
      expect(
        sortNodeList(
          nodes,
          mode: NodeSortMode.manual,
          descending: true,
        ).map((item) => item.id),
        ['c', 'b', 'a'],
      );
    });
  });

  group('group preferences', () {
    test('round-trips filters and sorting', () {
      final subscription = Subscription(
        id: 'group',
        name: '测试分组',
        includeFilter: '香港',
        excludeFilter: '剩余流量',
        sortMode: NodeSortMode.latency,
        sortDescending: true,
        nodes: [node('a', '香港 01')],
      );
      final restored = Subscription.fromJson(subscription.toJson());
      expect(restored.includeFilter, '香港');
      expect(restored.excludeFilter, '剩余流量');
      expect(restored.sortMode, NodeSortMode.latency);
      expect(restored.sortDescending, isTrue);
      expect(restored.isUrlSubscription, isFalse);
    });

    test('new subscriptions default to manual sorting', () {
      final restored = Subscription(
        id: 'new',
        name: '新分组',
        url: 'https://example.com/sub',
      );
      expect(restored.sortMode, NodeSortMode.manual);
      expect(restored.sortDescending, isFalse);
      expect(restored.includeFilter, isEmpty);
      expect(restored.isUrlSubscription, isTrue);
      expect(restored.copyWith(includeFilter: '香港').includeFilter, '香港');
    });
  });
}
