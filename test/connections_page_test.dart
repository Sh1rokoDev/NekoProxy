import 'package:flutter/material.dart';
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
        theme: ThemeData(useMaterial3: true),
        home: AppScope(controller: controller, child: const ConnectionsPage()),
      ),
    );
    await tester.pump();
  }

  testWidgets('连接卡片显示三行摘要、上传下载与节点名称', (tester) async {
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
          rule: 'AI 服务',
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
          rule: '屏蔽 QUIC',
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
    expect(
      find.descendant(of: proxy, matching: find.text('chatgpt.com')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: proxy,
        matching: find.text('127.0.0.1:49486 → 104.18.32.47:443'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: proxy, matching: find.text('1.5 KB')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: proxy, matching: find.text('15.8 KB')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: proxy, matching: find.text('日本 东京 · IPLC 01')),
      findsOneWidget,
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
      find.descendant(of: direct, matching: find.text('—')),
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
      find.descendant(of: blocked, matching: find.text('—')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏保持左右三行并截断长文本', (tester) async {
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
          rule: '这是一个非常长的命中规则名称',
          uploaded: 1024 * 1024,
          downloaded: 1024 * 1024 * 1024,
          createdAt: 0,
        ),
      ];

    await pumpPage(tester, controller, const Size(360, 800));

    final card = find.byKey(const ValueKey('long'));
    expect(card, findsOneWidget);
    final address = tester.widget<Text>(
      find.descendant(of: card, matching: find.text(longDomain)),
    );
    expect(address.maxLines, 1);
    expect(address.overflow, TextOverflow.ellipsis);
    final endpoint = tester.widget<Text>(
      find.descendant(
        of: card,
        matching: find.text('127.0.0.1:51248 → 203.0.113.24:443'),
      ),
    );
    expect(endpoint.maxLines, 1);
    expect(endpoint.overflow, TextOverflow.ellipsis);
    final nodeName = tester.widget<Text>(
      find.descendant(of: card, matching: find.text(longNodeName)),
    );
    expect(nodeName.maxLines, 1);
    expect(nodeName.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });
}

class _ConnectionsController extends AppController {
  _ConnectionsController(this.nodeNames);

  final Map<String, String> nodeNames;

  @override
  String? nodeNameForOutboundTag(String outboundTag) => nodeNames[outboundTag];

  @override
  Future<void> refreshConnections() async {}
}
