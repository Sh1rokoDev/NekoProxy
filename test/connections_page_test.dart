import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/features/tools/connections_page.dart';
import 'package:nekoproxy/runtime/runtime_client.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester,
    AppController controller,
    Size size,
  ) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          splashFactory: InkRipple.splashFactory,
        ),
        home: AppScope(controller: controller, child: const ConnectionsPage()),
      ),
    );
    await tester.pump();
  }

  testWidgets('连接卡片右上显示流量，右下可查看详情和关闭单条连接', (tester) async {
    final controller = _ConnectionsController({'node-proxy': '日本 东京 · IPLC 01'})
      ..running = true
      ..connections = const [
        RuntimeConnection(
          id: 'proxy',
          network: 'tcp',
          source: '127.0.0.1:49486',
          destination: '104.18.32.47:443',
          domain: 'chatgpt.com',
          outbound: 'node-proxy',
          rule: 'rule_set=geosite-ai',
          ruleIndex: 0,
          uploaded: 1536,
          downloaded: 16148,
          createdAt: 0,
        ),
        RuntimeConnection(
          id: 'direct',
          network: 'tcp',
          source: '127.0.0.1:49487',
          destination: 'ecs.office.com:443',
          domain: 'ecs.office.com',
          outbound: 'direct',
          rule: '',
          uploaded: 786,
          downloaded: 15770,
          createdAt: 0,
        ),
        RuntimeConnection(
          id: 'blocked',
          network: 'udp',
          source: '127.0.0.1:50712',
          destination: '142.250.72.14:443',
          domain: 'www.youtube.com',
          outbound: 'block',
          rule: 'port=443 network=udp',
          ruleIndex: 2,
          uploaded: 0,
          downloaded: 0,
          createdAt: 0,
        ),
      ];

    await pumpPage(tester, controller, const Size(980, 900));

    final proxy = find.byKey(const ValueKey('proxy'));
    expect(
      find.descendant(of: proxy, matching: find.text('TCP')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: proxy, matching: find.text('代理')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: proxy, matching: find.text('AI 服务')),
      findsOneWidget,
    );
    expect(find.textContaining('rule_set='), findsNothing);
    expect(
      find.descendant(of: proxy, matching: find.text('chatgpt.com')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: proxy,
        matching: find.text('127.0.0.1:49486 → 104.18.32.47:443'),
      ),
      findsNothing,
    );
    final upload = find.descendant(of: proxy, matching: find.text('1.5 KB'));
    final download = find.descendant(of: proxy, matching: find.text('15.8 KB'));
    final node = find.descendant(
      of: proxy,
      matching: find.text('日本 东京 · IPLC 01'),
    );
    expect(tester.getCenter(upload).dy, tester.getCenter(download).dy);
    expect(
      tester.getRect(upload).right,
      lessThan(tester.getRect(download).left),
    );
    final details = find.descendant(
      of: proxy,
      matching: find.byTooltip('查看详情'),
    );
    final close = find.descendant(of: proxy, matching: find.byTooltip('关闭连接'));
    expect(tester.getCenter(upload).dy, lessThan(tester.getCenter(proxy).dy));
    expect(
      tester.getCenter(download).dy,
      lessThan(tester.getCenter(details).dy),
    );
    expect(tester.getCenter(details).dy, tester.getCenter(close).dy);
    expect(tester.getRect(download).right, tester.getRect(close).right);
    expect(
      tester.getTopLeft(node).dx,
      tester.getTopLeft(find.text('chatgpt.com')).dx,
    );

    final direct = find.byKey(const ValueKey('direct'));
    expect(
      find.descendant(of: direct, matching: find.text('直连')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: direct, matching: find.text('未匹配')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: direct, matching: find.text('DIRECT')),
      findsOneWidget,
    );

    final blocked = find.byKey(const ValueKey('blocked'));
    expect(
      find.descendant(of: blocked, matching: find.text('UDP')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: blocked, matching: find.text('阻断')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: blocked, matching: find.text('屏蔽 QUIC')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: blocked, matching: find.text('DIRECT')),
      findsOneWidget,
    );

    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.text('连接详情'), findsOneWidget);
    expect(find.textContaining('来源地址：127.0.0.1:49486'), findsOneWidget);
    expect(find.textContaining('规则：AI 服务'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final search = find.byTooltip('搜索连接');
    expect(
      tester.getCenter(search).dx,
      lessThan(tester.getCenter(find.byTooltip('刷新')).dx),
    );
    await tester.tap(search);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  OFFICE.COM ');
    await tester.pump();
    expect(direct, findsOneWidget);
    expect(proxy, findsNothing);
    await tester.enterText(find.byType(TextField), '屏蔽 QUIC');
    await tester.pump();
    expect(blocked, findsOneWidget);
    expect(direct, findsNothing);
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();

    await tester.tap(close);
    await tester.pump();
    expect(controller.closedIds, ['proxy']);
    expect(proxy, findsNothing);
    expect(direct, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏连接卡片截断较长的目标和节点名', (tester) async {
    const longDomain = 'very-long-subdomain-for-connection-layout.example.com';
    const longNodeName = '这是一个非常长的节点名称用于验证截断行为';
    final controller = _ConnectionsController({'node-long': longNodeName})
      ..running = true
      ..connections = const [
        RuntimeConnection(
          id: 'long',
          network: 'tcp',
          source: '127.0.0.1:51248',
          destination: '203.0.113.24:443',
          domain: longDomain,
          outbound: 'node-long',
          rule: 'rule_set=geosite-example',
          uploaded: 1024 * 1024,
          downloaded: 1024 * 1024 * 1024,
          createdAt: 0,
        ),
      ];

    await pumpPage(tester, controller, const Size(320, 800));

    final card = find.byKey(const ValueKey('long'));
    expect(card, findsOneWidget);
    final upload = find.text('1.0 MB');
    final download = find.text('1.0 GB');
    expect(tester.getCenter(upload).dy, tester.getCenter(download).dy);
    final address = tester.widget<Text>(
      find.descendant(of: card, matching: find.text(longDomain)),
    );
    expect(address.maxLines, 1);
    expect(address.overflow, TextOverflow.ellipsis);
    final nodeName = tester.widget<Text>(
      find.descendant(of: card, matching: find.text(longNodeName)),
    );
    expect(nodeName.maxLines, 1);
    expect(nodeName.overflow, TextOverflow.ellipsis);
    expect(find.text('已匹配规则'), findsNothing);
    expect(find.text('未匹配'), findsNothing);
    expect(find.textContaining('rule_set='), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _ConnectionsController extends AppController {
  _ConnectionsController(this.nodeNames);

  final Map<String, String> nodeNames;
  final closedIds = <String>[];

  @override
  String? nodeNameForOutboundTag(String outboundTag) => nodeNames[outboundTag];

  @override
  String? nameForMatchedRule(int? index) => switch (index) {
    0 => 'AI 服务',
    2 => '屏蔽 QUIC',
    _ => null,
  };

  @override
  Future<void> refreshConnections() async {}

  @override
  Future<void> closeConnection(String id) async {
    closedIds.add(id);
    connections = [
      for (final item in connections)
        if (item.id != id) item,
    ];
  }
}
