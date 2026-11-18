import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/widgets.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/home/home_cards.dart';
import 'package:nekoproxy/features/home/home_page.dart';
import 'package:nekoproxy/features/status/service_status.dart';
import 'package:nekoproxy/runtime/runtime_client.dart';
import 'package:nekoproxy/services/exit_info_service.dart';
import 'package:nekoproxy/services/rule_set_manager.dart';
import 'package:nekoproxy/services/windows_system_proxy.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  RenderParagraph paragraphOf(WidgetTester tester, Finder text) =>
      tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );

  Future<void> showHome(
    WidgetTester tester,
    AppController controller,
    Size size,
  ) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: HomePage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('桌面首页使用紧凑连接工具条，复用双曲线，编辑笔位于原有开关右边', (tester) async {
    final controller = _Controller()
      ..settings.tunEnabled = true
      ..settings.systemProxyEnabled = true
      ..running = true
      ..connectedAt = DateTime.now()
      ..exitInfo = ExitInfo(
        ip: '203.0.113.24',
        region: '香港',
        provider: '示例 ISP · AS1234',
        checkedAt: DateTime.now(),
      )
      ..samples = [TrafficSample(DateTime.now(), 128, 4096)];
    await showHome(tester, controller, const Size(1280, 1000));
    final chart = tester.widget<TrafficSparkline>(
      find.byType(TrafficSparkline),
    );
    expect(chart.up, [128]);
    expect(chart.down, [4096]);
    expect(find.byType(TrafficSparkline), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey(HomeCard.connection)),
        matching: find.text('203.0.113.24'),
      ),
      findsOneWidget,
    );
    expect(find.byType(Switch), findsNWidgets(2));
    final connectionCard = find.byKey(const ValueKey(HomeCard.connection));
    final infoStrip = find.byKey(const ValueKey('connection-info-strip'));
    expect(infoStrip, findsOneWidget);
    expect(
      find.descendant(of: connectionCard, matching: find.text('TUN')),
      findsNothing,
    );
    expect(
      find.descendant(of: connectionCard, matching: find.text('系统代理')),
      findsNothing,
    );
    expect(find.text('TUN'), findsOneWidget);
    expect(find.text('系统代理'), findsOneWidget);
    expect(
      tester.getTopLeft(infoStrip).dx,
      greaterThan(tester.getTopRight(find.text('还没有节点')).dx),
    );
    expect(
      tester.getCenter(find.byTooltip('编辑首页')).dx,
      greaterThan(tester.getCenter(find.byType(Switch).last).dx),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey(HomeCard.connection))).height,
      lessThan(300),
    );
  });

  testWidgets('首页连接卡独占首行，其余卡片等宽并补到较短的一列', (tester) async {
    final controller = _Controller();
    for (final layout in [
      controller.settings.homeDesktop,
      controller.settings.homeMobile,
    ]) {
      layout.hidden.add(HomeCard.services);
      layout.order
        ..remove(HomeCard.splitMode)
        ..insert(2, HomeCard.splitMode);
    }
    await showHome(tester, controller, const Size(760, 1000));

    Rect bounds(HomeCard card) => tester.getRect(find.byKey(ValueKey(card)));
    final connection = bounds(HomeCard.connection);
    final traffic = bounds(HomeCard.traffic);
    final mode = bounds(HomeCard.splitMode);
    final subscription = bounds(HomeCard.subscription);
    final activity = bounds(HomeCard.activity);
    expect(find.byKey(const ValueKey(HomeCard.services)), findsNothing);
    expect(connection.left, traffic.left);
    expect(connection.right, mode.right);
    expect(connection.bottom, lessThan(mode.top));
    expect(traffic.top, mode.top);
    expect(traffic.right, lessThan(mode.left));
    expect(subscription.left, mode.left);
    expect(subscription.top, closeTo(mode.bottom + 16, 0.01));
    expect(subscription.top, lessThan(traffic.bottom));
    final shorter = traffic.bottom <= subscription.bottom
        ? traffic
        : subscription;
    expect(activity.left, shorter.left);
    expect(activity.top, closeTo(shorter.bottom + 16, 0.01));
    for (final card in [traffic, subscription, activity]) {
      expect(card.width, mode.width);
    }
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(759, 1000));
    await tester.pumpAndSettle();
    var previous = bounds(HomeCard.connection);
    for (final kind in [
      HomeCard.traffic,
      HomeCard.splitMode,
      HomeCard.subscription,
      HomeCard.activity,
    ]) {
      final card = bounds(kind);
      expect(card.left, previous.left);
      expect(card.width, previous.width);
      expect(card.top, greaterThan(previous.bottom));
      previous = card;
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 仅 WireGuard 模式可切换并保存 TUN 设置', (tester) async {
    final storage = _Storage();
    final controller = _Controller()
      ..storage = storage
      ..snapshot.outboundMode = OutboundMode.wireGuard;
    await showHome(tester, controller, const Size(1280, 1000));

    final tunSwitch = find.descendant(
      of: find.widgetWithText(Row, 'TUN').first,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(tunSwitch).value, isFalse);
    expect(find.text('仅接管代理流量'), findsOneWidget);
    await tester.tap(tunSwitch);
    await tester.pumpAndSettle();
    expect(storage.saved?.settings.tunEnabled, isTrue);
    expect(tester.widget<Switch>(tunSwitch).value, isTrue);
    expect(find.text('按 AllowedIPs 路由'), findsOneWidget);
    await tester.tap(tunSwitch);
    await tester.pumpAndSettle();
    expect(storage.saved?.settings.tunEnabled, isFalse);
    expect(tester.widget<Switch>(tunSwitch).value, isFalse);
  });

  for (final android in [false, true]) {
    final label = android ? 'VPN' : 'TUN';
    testWidgets('$label 在断开时只保存，连接中自动重启并保持电源按钮状态', (tester) async {
      final controller = _TakeoverController(android: android);
      if (android) {
        controller.settings
          ..perAppMode = PerAppMode.allow
          ..perAppPackages = [];
      }
      final runtime = controller.testRuntime;
      await showHome(
        tester,
        controller,
        android ? const Size(460, 1000) : const Size(1280, 1000),
      );
      final takeover = find.descendant(
        of: find.widgetWithText(Row, label).first,
        matching: find.byType(Switch),
      );
      final power = find.byKey(const ValueKey('connection-power'));
      Finder powerLabel(String text) =>
          find.descendant(of: power, matching: find.text(text));

      expect(tester.widget<Switch>(takeover).value, android);
      await tester.tap(takeover);
      await tester.pumpAndSettle();
      expect(runtime.modes, isEmpty);
      expect(powerLabel('连接'), findsOneWidget);
      if (!android) {
        await tester.tap(takeover);
        await tester.pumpAndSettle();
      }

      await tester.tap(power);
      await tester.pumpAndSettle();
      expect(runtime.modes, ['normal']);
      expect(runtime.hasTun, [false]);
      expect(powerLabel('断开'), findsOneWidget);
      if (android) {
        await tester.tap(takeover);
        await tester.pumpAndSettle();
        expect(runtime.modes, ['normal']);
        expect(controller.error, contains('请先选择应用'));
        controller.settings.perAppPackages = ['com.example.app'];
      }

      final restart = runtime.nextStart = Completer<void>();
      await tester.tap(takeover);
      await tester.pump();
      expect(runtime.modes, ['normal', 'tun']);
      expect(runtime.hasTun, [false, true]);
      expect(runtime.stops, 1);
      expect(powerLabel('断开'), findsOneWidget);
      expect(tester.widget<FilledButton>(power).onPressed, isNull);

      restart.complete();
      await tester.pumpAndSettle();
      expect(controller.running, isTrue);
      expect(controller.usesTun, isTrue);
      expect(tester.widget<Switch>(takeover).value, isTrue);
      await tester.tap(takeover);
      await tester.pumpAndSettle();
      expect(runtime.modes, ['normal', 'tun', 'normal']);
      expect(controller.running, isTrue);
      expect(controller.usesTun, isFalse);
      expect(powerLabel('断开'), findsOneWidget);

      await tester.tap(power);
      await tester.pumpAndSettle();
      expect(powerLabel('连接'), findsOneWidget);
    });
  }

  test('Windows 系统代理在核心运行中即时切换，断开时只保存', () async {
    final controller = _TakeoverController(android: false);
    addTearDown(controller.dispose);
    final proxy = _SystemProxy(controller.paths);
    controller.systemProxy = proxy;
    final runtime = controller.testRuntime;

    await controller.setSystemProxy(true);
    expect(controller.running, isFalse);
    expect(runtime.modes, isEmpty);
    expect(proxy.enabled, isFalse);

    await controller.connect();
    expect(proxy.enabled, isTrue);
    await controller.setSystemProxy(false);
    expect(proxy.enabled, isFalse);
    await controller.setSystemProxy(true);
    expect(proxy.enabled, isTrue);
    expect(controller.running, isTrue);
    expect(runtime.modes, ['normal']);
    expect(runtime.stops, 0);

    await controller.disconnect();
    expect(proxy.enabled, isFalse);
    expect(controller.settings.systemProxyEnabled, isTrue);
  });

  test('VPN 重启失败后恢复原先的本地代理连接', () async {
    final controller = _TakeoverController(android: true)
      ..settings.vpnEnabled = false;
    addTearDown(controller.dispose);
    await controller.connect();
    controller.testRuntime.failTun = true;
    await controller.setTun(true);
    expect(controller.testRuntime.modes, ['normal', 'tun', 'normal']);
    expect(controller.running, isTrue);
    expect(controller.settings.vpnEnabled, isFalse);
    expect(
      (controller.storage as _Storage).saved?.settings.vpnEnabled,
      isFalse,
    );
    expect(controller.error, contains('已恢复原接管方式'));
    await controller.disconnect();
  });

  testWidgets('仅 WireGuard 模式显示所属分组及隧道测速结果', (tester) async {
    final controller = _WireGuardConnectionController()
      ..running = true
      ..snapshot = AppSnapshot(
        settings: AppSettings(manualNodeId: 'proxy'),
        subscriptions: [
          Subscription(
            id: 'proxy-group',
            name: '普通代理分组',
            nodes: [
              ProxyNode(id: 'proxy', tag: 'proxy', name: '代理', outbound: {}),
            ],
          ),
        ],
        outboundMode: OutboundMode.wireGuard,
        wireGuardProfileId: 'wg',
        wireGuardGroups: [const WireGuardGroup(id: 'campus', name: '校园隧道')],
        wireGuardProfiles: [
          WireGuardProfile(
            id: 'wg',
            name: '测试节点',
            groupId: 'campus',
            configuration: '',
          ),
        ],
      )
      ..latencies = {'proxy': 999}
      ..wireGuardLatency = const RuntimeTestResult(delay: 42);
    await showHome(tester, controller, const Size(1280, 1000));

    Finder within(String key, Finder matching) =>
        find.descendant(of: find.byKey(ValueKey(key)), matching: matching);
    expect(within('connection-source', find.text('校园隧道')), findsOneWidget);
    expect(within('connection-latency', find.text('42ms')), findsOneWidget);
    expect(within('connection-latency', find.text('999ms')), findsNothing);
  });

  testWidgets('订阅用量随订阅节点和 WireGuard 节点切换更新', (tester) async {
    final controller = _TakeoverController(android: false);
    final group = controller.snapshot.subscriptions.single;
    final node = group.nodes.single.copyWith(subscriptionId: group.id);
    final subscription = group.copyWith(
      url: 'https://example.com/subscription',
      nodes: [node],
    );
    final key = base64Encode(List.filled(32, 2));
    controller.snapshot.subscriptions[0] = subscription;
    controller.settings.manualNodeId = node.id;
    controller.snapshot.wireGuardProfiles = [
      WireGuardProfile(
        id: 'wg',
        name: '测试隧道',
        configuration:
            '''
[Interface]
PrivateKey = $key
Address = 10.0.0.2/24
[Peer]
PublicKey = $key
Endpoint = 192.0.2.1:51820
AllowedIPs = 0.0.0.0/0
''',
      ),
    ];
    await showHome(tester, controller, const Size(1280, 1000));

    final card = find.byType(HomeSubscriptionCard);
    final overview = find.descendant(
      of: card,
      matching: find.text(subscription.name),
    );
    final emptyState = find.text('当前节点不属于订阅，请在节点页选择订阅节点');
    IconButton refreshButton() => tester.widget<IconButton>(
      find.descendant(of: card, matching: find.byType(IconButton)),
    );

    expect(overview, findsOneWidget);
    expect(refreshButton().onPressed, isNotNull);

    await controller.selectWireGuard('wg');
    await tester.pumpAndSettle();
    expect(overview, findsNothing);
    expect(emptyState, findsOneWidget);
    expect(refreshButton().onPressed, isNull);

    await controller.setChainProxyEnabled(true);
    await tester.pumpAndSettle();
    expect(overview, findsOneWidget);
    expect(emptyState, findsNothing);

    await controller.setChainProxyEnabled(false);
    await tester.pumpAndSettle();
    expect(emptyState, findsOneWidget);

    await controller.selectNode(node.id);
    await tester.pumpAndSettle();
    expect(overview, findsOneWidget);
    expect(emptyState, findsNothing);
    expect(refreshButton().onPressed, isNotNull);
  });

  testWidgets('链式代理按实际顺序展示各级节点、来源及分隔线', (tester) async {
    final node = ProxyNode(
      id: 'p',
      tag: 'p',
      name: '二级代理',
      subscriptionId: 'sub',
      outbound: {'server': 'example.net', 'server_port': 443},
    );
    final controller = _Controller()
      ..snapshot = AppSnapshot(
        settings: AppSettings(manualNodeId: node.id),
        outboundMode: OutboundMode.wireGuardProxy,
        subscriptions: [
          Subscription(id: 'sub', name: '代理分组', nodes: [node]),
        ],
        wireGuardGroups: [const WireGuardGroup(id: 'wg-group', name: '隧道分组')],
        wireGuardProfileId: 'w',
        wireGuardProfiles: [
          WireGuardProfile(
            id: 'w',
            name: '一级隧道',
            groupId: 'wg-group',
            configuration: '',
          ),
        ],
      );
    await showHome(tester, controller, const Size(880, 1000));
    final card = find.byKey(const ValueKey(HomeCard.connection));
    Finder inCard(String s) =>
        find.descendant(of: card, matching: find.text(s));
    for (final width in [1280.0, 760.0, 320.0]) {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(inCard('第一级')).dy,
        closeTo(tester.getCenter(inCard('WireGuard')).dy, 1),
      );
      expect(
        tester.getCenter(inCard('第二级')).dy,
        closeTo(tester.getCenter(inCard('SingBox')).dy, 1),
      );
      expect(
        tester.getCenter(inCard('隧道分组')).dy,
        closeTo(tester.getCenter(inCard('WireGuard')).dy, 1),
      );
      expect(
        tester.getCenter(inCard('代理分组')).dy,
        closeTo(tester.getCenter(inCard('SingBox')).dy, 1),
      );
      if (width == 1280) {
        final line = find.descendant(
          of: card,
          matching: find.byType(VerticalDivider),
        );
        final row = tester.getRect(
          find.ancestor(of: line, matching: find.byType(Row)).first,
        );
        expect(tester.getCenter(line).dx, closeTo(row.center.dx, 1));
        expect(
          tester.getRect(inCard('第一级')).right,
          lessThan(tester.getRect(line).left),
        );
        expect(
          tester.getRect(inCard('第二级')).left,
          greaterThan(tester.getCenter(line).dx),
        );
        expect(
          tester.getTopLeft(inCard('第一级')).dy,
          tester.getTopLeft(inCard('第二级')).dy,
        );
      } else {
        final line = find.descendant(of: card, matching: find.byType(Divider));
        expect(
          tester.getBottomLeft(inCard('一级隧道')).dy,
          lessThan(tester.getCenter(line).dy),
        );
        expect(
          tester.getCenter(line).dy,
          lessThan(tester.getTopLeft(inCard('第二级')).dy),
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('未连接卡片保持紧凑，三项诊断值统一显示为未知', (tester) async {
    final controller = _Controller();
    await showHome(tester, controller, const Size(1280, 1000));
    final card = find.byKey(const ValueKey(HomeCard.connection));
    expect(tester.getSize(card).height, lessThan(250));
    expect(
      (tester.getCenter(find.text('未连接')).dy -
              tester.getCenter(find.text('手动选择')).dy)
          .abs(),
      lessThan(5),
    );
    final unknownValues = find.descendant(
      of: find.byKey(const ValueKey('connection-info-strip')),
      matching: find.text('未知'),
    );
    expect(unknownValues, findsNWidgets(3));
    final styles = [
      for (var i = 0; i < 3; i++)
        paragraphOf(tester, unknownValues.at(i)).text.style,
    ];
    expect(styles, everyElement(styles.last));
    expect(find.byTooltip('刷新出口、运营商和节点延迟'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机连接卡的状态、时长和模式在节点名称上方连续排列', (tester) async {
    final controller = _Controller(android: true)
      ..settings.splitMode = SplitMode.rule;
    await showHome(tester, controller, const Size(390, 900));
    final card = find.byKey(const ValueKey(HomeCard.connection));
    Finder label(String text) =>
        find.descendant(of: card, matching: find.text(text));

    final status = tester.getCenter(label('未连接'));
    var previous = status;
    for (final text in ['—', '手动选择']) {
      final center = tester.getCenter(label(text).first);
      expect(center.dy, closeTo(status.dy, 1));
      expect(center.dx, greaterThan(previous.dx));
      previous = center;
    }
    expect(label('规则分流'), findsNothing);
    expect(status.dy, lessThan(tester.getTopLeft(label('还没有节点')).dy));
  });

  for (final width in [320.0, 360.0, 390.0, 428.0]) {
    testWidgets('$width 宽手机首页先显示服务状态，标题操作保持在右上角', (tester) async {
      final controller = _Controller(android: true);
      await showHome(tester, controller, Size(width, 900));

      final services = tester.getRect(
        find.byKey(const ValueKey(HomeCard.services)),
      );
      final activity = tester.getRect(
        find.byKey(const ValueKey(HomeCard.activity)),
      );
      final title = tester.getRect(find.text('首页'));
      final edit = tester.getRect(find.byTooltip('编辑首页'));

      expect(services.top, lessThan(activity.top));
      expect(edit.center.dy, closeTo(title.center.dy, 1));
      expect(edit.left, greaterThan(title.right));
      expect(edit.right, closeTo(width - 24, 1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('实时通知更新流量，并保留其它首页卡片的组件实例', (tester) async {
    final controller = _Controller();
    await showHome(tester, controller, const Size(1280, 1000));
    final subscription = tester.widget(find.byType(HomeSubscriptionCard));
    final services = tester.widget(find.byType(ServiceStatusCard));
    final activity = tester.widget(find.byType(HomeActivityCard));

    controller.samples = [TrafficSample(DateTime.now(), 512, 2048)];
    controller.liveTick.value++;
    await tester.pump();

    final chart = tester.widget<TrafficSparkline>(
      find.byType(TrafficSparkline),
    );
    expect(chart.up, [512]);
    expect(chart.down, [2048]);
    expect(
      tester.widget(find.byType(HomeSubscriptionCard)),
      same(subscription),
    );
    expect(tester.widget(find.byType(ServiceStatusCard)), same(services));
    expect(tester.widget(find.byType(HomeActivityCard)), same(activity));
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏诊断靠右，窄屏诊断置底，两种宽度均保留文字按钮', (tester) async {
    final node = ProxyNode(
      id: 'node',
      tag: 'node',
      name: '香港实验性 IEPL 专线 1',
      outbound: {'server': 'example.net', 'server_port': 10011},
      subscriptionId: 'sub',
    );
    final controller = _RefreshController()
      ..running = true
      ..connectedAt = DateTime.now().subtract(const Duration(minutes: 6))
      ..settings.selectionMode = SelectionMode.auto
      ..settings.manualNodeId = node.id
      ..snapshot.subscriptions.add(
        Subscription(id: 'sub', name: 'sub.example.net', nodes: [node]),
      )
      ..latencies = {node.id: 47}
      ..exitInfo = ExitInfo(
        ip: '192.0.2.1',
        region: 'Japan · Tokyo',
        provider: '示例运营商',
        checkedAt: DateTime(2026, 11, 12, 20),
      );
    await showHome(tester, controller, const Size(880, 1000));
    final connectionCard = find.byKey(const ValueKey(HomeCard.connection));
    Finder inCard(String text) =>
        find.descendant(of: connectionCard, matching: find.text(text));
    final power = find.byKey(const ValueKey('connection-power'));
    final refresh = find.byTooltip('刷新出口、运营商和节点延迟');
    final title = inCard(node.name);
    final mode = inCard('自动选择');
    final status = inCard('已连接');
    final ip = inCard('192.0.2.1');
    final address = inCard('example.net:10011');
    final region = inCard('Japan · Tokyo');
    void expectSingleLineIpAndBadgeBeforeAddress() {
      final ipText = paragraphOf(tester, ip);
      expect(ipText.didExceedMaxLines, isFalse);
      for (final value in ['192.0.2.1', '示例运营商', '47ms', 'sub.example.net']) {
        final paragraph = paragraphOf(tester, inCard(value));
        expect(paragraph.maxLines, 1);
        expect(paragraph.overflow, TextOverflow.ellipsis);
      }
      expect(
        tester.getRect(region).right,
        lessThan(tester.getRect(address).left),
      );
      expect(
        tester.getCenter(region).dy,
        closeTo(tester.getCenter(address).dy, 1),
      );
      final badgeText = tester.renderObject<RenderParagraph>(region);
      expect(
        badgeText.size.width,
        closeTo(badgeText.getMaxIntrinsicWidth(double.infinity), 1),
      );
      expect(
        tester.getTopLeft(region).dy - tester.getRect(title).bottom,
        greaterThanOrEqualTo(6),
      );
    }

    for (final title in ['出口 IP', '运营商', '节点延迟', '来源']) {
      expect(inCard(title), findsOneWidget);
    }
    expect(inCard('示例运营商'), findsOneWidget);
    expect(inCard('47ms'), findsOneWidget);
    expect(inCard('sub.example.net'), findsOneWidget);
    expect(inCard('地区'), findsNothing);
    expect(inCard('断开'), findsOneWidget);
    expect(tester.getSize(power).height, greaterThan(40));
    expect(tester.getRect(refresh).right, lessThan(tester.getRect(power).left));
    expect(tester.getRect(refresh).top, tester.getRect(power).top);
    expect(tester.getSize(refresh), tester.getSize(power));
    expect(
      tester.getTopLeft(power).dy,
      greaterThan(tester.getBottomLeft(inCard('节点延迟')).dy),
    );
    expect(find.byTooltip('复制出口 IP'), findsNothing);
    expect(find.byTooltip('刷新出口信息'), findsNothing);
    await tester.tap(refresh);
    expect(controller.refreshes, 1);
    expect(tester.getCenter(mode).dy, closeTo(tester.getCenter(status).dy, 3));
    for (final (label, value) in [
      ('出口 IP', '192.0.2.1'),
      ('运营商', '示例运营商'),
      ('节点延迟', '47ms'),
    ]) {
      expect(
        tester.getCenter(inCard(label)).dy,
        closeTo(tester.getCenter(inCard(value)).dy, 2),
      );
      expect(
        tester.getTopLeft(inCard(label)).dx,
        greaterThan(tester.getTopRight(title).dx),
      );
    }
    expect(
      tester.getCenter(inCard('SingBox')).dy,
      closeTo(tester.getCenter(inCard('sub.example.net')).dy, 1),
    );
    expectSingleLineIpAndBadgeBeforeAddress();
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(400, 1000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(inCard('断开'), findsOneWidget);
    expect(tester.getRect(refresh).right, lessThan(tester.getRect(power).left));
    expect(tester.getRect(refresh).top, tester.getRect(power).top);
    expect(tester.getSize(refresh), tester.getSize(power));
    expect(tester.getCenter(mode).dy, closeTo(tester.getCenter(status).dy, 3));
    expect(tester.getRect(mode).bottom, lessThan(tester.getTopLeft(title).dy));
    final exit = tester.getTopLeft(inCard('出口 IP'));
    final provider = tester.getTopLeft(inCard('运营商'));
    final latency = tester.getTopLeft(inCard('节点延迟'));
    expect(provider.dx, exit.dx);
    expect(latency.dx, exit.dx);
    expect(provider.dy, greaterThan(exit.dy));
    expect(latency.dy, greaterThan(provider.dy));
    expect(exit.dy, greaterThan(tester.getBottomLeft(address).dy));
    expect(tester.getTopLeft(power).dy, greaterThan(latency.dy));
    expectSingleLineIpAndBadgeBeforeAddress();
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页切换规则模式会保存并更新选中项，保存失败时恢复原模式', (tester) async {
    final storage = _Storage();
    final controller = _ConnectedModeController()
      ..running = true
      ..storage = storage;
    await showHome(tester, controller, const Size(390, 900));
    final card = find.byKey(const ValueKey(HomeCard.splitMode));
    Finder option(String label) =>
        find.descendant(of: card, matching: find.text(label));
    final control = find.descendant(
      of: card,
      matching: find.byType(SlidingSegmentedControl<SplitMode>),
    );
    expect(
      tester.widget<SlidingSegmentedControl<SplitMode>>(control).selected,
      SplitMode.rule,
    );

    await tester.tap(option('全局'));
    await tester.pump();
    expect(storage.saved?.settings.splitMode, SplitMode.global);
    expect(controller.restarts, 1);
    expect(
      tester.widget<SlidingSegmentedControl<SplitMode>>(control).selected,
      SplitMode.global,
    );

    storage.fail = true;
    await tester.tap(option('直连'));
    await tester.pump();
    expect(controller.settings.splitMode, SplitMode.global);
    expect(controller.restarts, 1);
    expect(controller.error, startsWith('规则模式保存失败'));
    expect(
      tester.widget<SlidingSegmentedControl<SplitMode>>(control).selected,
      SplitMode.global,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片可隐藏排序并保存，手机和桌面布局分别保留', (tester) async {
    final storage = _Storage();
    final controller = _Controller()..storage = storage;
    await showHome(tester, controller, const Size(1280, 1000));
    await tester.tap(find.byTooltip('编辑首页'));
    await tester.pump();
    expect(find.byTooltip('移除连接与出口信息'), findsNothing);
    expect(find.byType(LongPressDraggable<HomeCard>), findsNWidgets(5));
    await tester.tap(find.byTooltip('移除订阅用量'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byType(HomeSubscriptionCard), findsNothing);

    final addCard = find.widgetWithText(TextButton, '添加卡片');
    Rect bounds(HomeCard kind) => tester.getRect(find.byKey(ValueKey(kind)));
    final left = bounds(HomeCard.splitMode).left;
    final cardBounds = [
      for (final kind in [
        HomeCard.splitMode,
        HomeCard.traffic,
        HomeCard.services,
        HomeCard.activity,
      ])
        bounds(kind),
    ];
    final leftBottom = cardBounds
        .where((rect) => rect.left == left)
        .map((rect) => rect.bottom)
        .reduce((a, b) => a > b ? a : b);
    final rightBottom = cardBounds
        .where((rect) => rect.left != left)
        .map((rect) => rect.bottom)
        .reduce((a, b) => a > b ? a : b);
    final addBounds = tester.getRect(addCard);
    expect(addBounds.width, cardBounds.first.width);
    expect(
      addBounds.top,
      (leftBottom <= rightBottom ? leftBottom : rightBottom) + 16,
    );
    expect(
      addBounds.left,
      leftBottom <= rightBottom ? left : bounds(HomeCard.traffic).left,
    );
    await tester.ensureVisible(addCard);
    await tester.tap(addCard);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.widgetWithText(ListTile, '规则模式'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, '订阅用量'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(HomeSubscriptionCard), findsOneWidget);

    final trafficCard = find.byKey(const ValueKey(HomeCard.traffic));
    await tester.ensureVisible(trafficCard);
    final trafficContent = find.byType(HomeTrafficCard);
    final initialTransform = tester
        .renderObject(trafficContent)
        .getTransformTo(null);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.renderObject(trafficContent).getTransformTo(null),
      initialTransform,
    );
    final before = bounds(HomeCard.splitMode);
    final gesture = await tester.startGesture(tester.getCenter(trafficCard));
    await tester.pump(const Duration(milliseconds: 200));
    expect(trafficContent, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 60));
    expect(trafficContent, findsNWidgets(2));
    final floatingCard = find.byType(HomeTrafficCard).last;
    final floatingStart = tester.getRect(floatingCard);
    expect(floatingStart.size, bounds(HomeCard.traffic).size);
    await gesture.moveTo(before.center);
    await tester.pump();
    expect(tester.getRect(floatingCard).left, lessThan(floatingStart.left));
    await tester.pump(const Duration(milliseconds: 70));
    final moving = bounds(HomeCard.splitMode);
    expect(moving.left, greaterThan(before.left));
    await tester.pump(const Duration(milliseconds: 150));
    expect(bounds(HomeCard.splitMode).left, greaterThan(moving.left));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey(HomeCard.traffic))).dx,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey(HomeCard.splitMode))).dx,
      ),
    );
    expect(storage.saved, isNull);
    await gesture.up();
    await tester.pump();

    await tester.ensureVisible(find.byTooltip('移除订阅用量'));
    await tester.tap(find.byTooltip('移除订阅用量'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(find.byTooltip('完成编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(storage.saved, isNotNull);
    expect(
      storage.saved!.settings.homeDesktop.hidden,
      contains(HomeCard.subscription),
    );
    final order = storage.saved!.settings.homeDesktop.order;
    expect(order.take(3), [
      HomeCard.connection,
      HomeCard.traffic,
      HomeCard.splitMode,
    ]);
    expect(storage.saved!.settings.homeMobile.hidden, isEmpty);
    await tester.binding.setSurfaceSize(const Size(390, 900));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(HomeSubscriptionCard), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(HomeSubscriptionCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败保留编辑草稿，取消后恢复原布局', (tester) async {
    final storage = _Storage()..fail = true;
    final controller = _Controller()..storage = storage;
    await showHome(tester, controller, const Size(1280, 1000));
    await tester.tap(find.byTooltip('编辑首页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byTooltip('移除订阅用量'));
    await tester.pump();
    await tester.tap(find.byTooltip('完成编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('首页布局保存失败，请重试'), findsOneWidget);
    expect(find.byTooltip('完成编辑'), findsOneWidget);
    expect(find.byType(HomeSubscriptionCard), findsNothing);
    expect(controller.settings.homeDesktop.order, HomeCard.values);
    await tester.tap(find.byTooltip('取消编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byTooltip('编辑首页'), findsOneWidget);
    expect(find.byType(HomeSubscriptionCard), findsOneWidget);
    expect(controller.settings.homeDesktop.order, HomeCard.values);
  });

  for (final android in [true, false]) {
    testWidgets('320宽度${android ? 'Android' : 'Windows'}首页及编辑状态没有溢出', (
      tester,
    ) async {
      final controller = _Controller(android: android);
      await showHome(tester, controller, const Size(320, 900));
      expect(tester.takeException(), isNull);
      expect(find.text(android ? 'VPN' : 'TUN'), findsOneWidget);
      await tester.tap(find.byTooltip('编辑首页'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('编辑首页'), findsOneWidget);
      final addCard = tester.getRect(
        find.byKey(const ValueKey('add-home-card')),
      );
      final activity = tester.getRect(
        find.byKey(const ValueKey(HomeCard.activity)),
      );
      expect(addCard.width, activity.width);
      expect(addCard.top, activity.bottom + 16);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('已连接的长节点名、IPv6及订阅数据在窄屏与桌面布局均可显示', (tester) async {
    final node = ProxyNode(
      id: 'node',
      tag: 'node',
      name: '香港实验性 IEPL 专线 · 这是一个很长的节点名称',
      subscriptionId: 'group',
      outbound: const {
        'type': 'trojan',
        'server': 'example.com',
        'server_port': 443,
      },
    );
    final expiry = DateTime.now().add(const Duration(days: 23, minutes: 1));
    final controller = _Controller()
      ..running = true
      ..connectedAt = DateTime.now().subtract(const Duration(days: 15))
      ..latencies = {'node': 32}
      ..exitInfo = ExitInfo(
        ip: '2001:db8:1234:5678:1234:5678:1234:abcd',
        region: '中国香港 · 香港特别行政区',
        provider: '示例长名称网络运营商 · AS123456',
        checkedAt: DateTime.now(),
      )
      ..snapshot = AppSnapshot(
        settings: AppSettings(manualNodeId: 'node'),
        subscriptions: [
          Subscription(
            id: 'other',
            name: '其他订阅',
            url: 'https://example.com/other',
            totalBytes: 1024,
          ),
          Subscription(
            id: 'group',
            name: 'Neko 订阅',
            url: 'https://example.com/sub',
            nodes: [node],
            updateIntervalMinutes: 360,
            lastUpdated: DateTime(2026, 11, 12, 15, 57),
            totalBytes: 200 * 1024 * 1024,
            uploadBytes: 10 * 1024 * 1024,
            downloadBytes: 48 * 1024 * 1024,
            expireAt: expiry,
          ),
        ],
      );
    await showHome(tester, controller, const Size(320, 1000));
    expect(find.text('32ms'), findsOneWidget);
    final ipv6 = find.text('2001:db8:1234:5678:1234:5678:1234:abcd');
    expect(paragraphOf(tester, ipv6).didExceedMaxLines, isTrue);
    final connection = find.byKey(const ValueKey(HomeCard.connection));
    final selectionMode = find.descendant(
      of: connection,
      matching: find.text('手动选择'),
    );
    expect(
      tester.getBottomLeft(selectionMode).dy,
      lessThan(tester.getTopLeft(find.text(node.name)).dy),
    );
    final subscriptionCard = find.byKey(const ValueKey(HomeCard.subscription));
    Finder inCard(String text) =>
        find.descendant(of: subscriptionCard, matching: find.text(text));
    expect(inCard('Neko 订阅'), findsOneWidget);
    expect(inCard('其他订阅'), findsNothing);
    expect(
      find.descendant(
        of: subscriptionCard,
        matching: find.byType(DropdownButton<String>),
      ),
      findsNothing,
    );
    expect(inCard('当前订阅 · 1 个节点'), findsOneWidget);
    expect(inCard('已用 58.0 MB / 200.0 MB'), findsOneWidget);
    expect(inCard('29%'), findsOneWidget);
    expect(inCard('上传'), findsOneWidget);
    expect(inCard('10.0 MB'), findsOneWidget);
    expect(inCard('下载'), findsOneWidget);
    expect(inCard('48.0 MB'), findsOneWidget);
    expect(inCard('剩余'), findsOneWidget);
    expect(inCard('142.0 MB'), findsOneWidget);
    expect(
      find.descendant(
        of: subscriptionCard,
        matching: find.textContaining('剩余 23 天'),
      ),
      findsOneWidget,
    );
    expect(inCard('每 6 小时'), findsOneWidget);
    expect(inCard('2026-11-12 15:57'), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final width in [390.0, 760.0, 820.0, 1024.0, 1280.0]) {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull, reason: 'width $width');
    }
  });

  testWidgets('订阅缺少周期时首页显示默认 24 小时', (tester) async {
    final controller = _Controller()
      ..snapshot = AppSnapshot(
        settings: AppSettings(),
        subscriptions: [
          Subscription(
            id: 'default-interval',
            name: '默认周期订阅',
            url: 'https://example.com/default',
            autoUpdate: true,
          ),
        ],
      );

    await showHome(tester, controller, const Size(1280, 1000));
    final subscriptionCard = find.byKey(const ValueKey(HomeCard.subscription));
    expect(
      find.descendant(of: subscriptionCard, matching: find.text('每 24 小时')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: subscriptionCard,
        matching: find.textContaining('未提供周期'),
      ),
      findsNothing,
    );
  });

  testWidgets('订阅概览图标与文字整体垂直居中', (tester) async {
    const subscriptionName = 'sub.66688877.xyz';
    final node = ProxyNode(
      id: 'node',
      tag: 'node',
      name: '香港节点',
      subscriptionId: 'subscription',
      outbound: {'type': 'trojan', 'server': 'example.com', 'server_port': 443},
    );
    final controller = _Controller()
      ..snapshot = AppSnapshot(
        settings: AppSettings(manualNodeId: 'node'),
        subscriptions: [
          Subscription(
            id: 'subscription',
            name: subscriptionName,
            url: 'https://example.com/sub',
            nodes: [node],
          ),
        ],
      );

    await showHome(tester, controller, const Size(1280, 1000));
    final subscriptionCard = find.byKey(const ValueKey(HomeCard.subscription));
    final icon = find.descendant(
      of: subscriptionCard,
      matching: find.byIcon(Icons.rss_feed_rounded),
    );
    final title = find.descendant(
      of: subscriptionCard,
      matching: find.text(subscriptionName),
    );
    final subtitle = find.descendant(
      of: subscriptionCard,
      matching: find.text('当前订阅 · 1 个节点'),
    );
    final textCenter =
        (tester.getRect(title).top + tester.getRect(subtitle).bottom) / 2;

    expect(tester.getCenter(icon).dy, moreOrLessEquals(textCenter));
  });
}

class _Controller extends AppController {
  _Controller({this.android = false});
  final bool android;
  @override
  bool get isAndroid => android;
  @override
  bool get supportsSystemProxy => !android;
}

class _ConnectedModeController extends _Controller {
  _ConnectedModeController() : super(android: true);

  int restarts = 0;

  @override
  Future<void> restartCore() async => restarts++;
}

class _TakeoverController extends _Controller {
  _TakeoverController({required super.android}) {
    storage = _Storage();
    paths = storage.paths;
    runtime = testRuntime;
    ruleSets = RuleSetManager(paths: paths, clientFactory: HttpClient.new);
    snapshot.subscriptions.add(
      Subscription(
        id: 'proxy-group',
        name: '测试分组',
        nodes: [
          ProxyNode(
            id: 'proxy',
            tag: 'proxy',
            name: '测试代理',
            outbound: const {
              'type': 'trojan',
              'server': 'example.com',
              'server_port': 443,
              'password': 'test',
            },
          ),
        ],
      ),
    );
  }

  final testRuntime = _TakeoverRuntime();

  @override
  Future<void> refreshExitInfo() async {}
}

class _TakeoverRuntime extends RuntimeClient {
  final modes = <String>[];
  final hasTun = <bool>[];
  int stops = 0;
  bool failTun = false;
  Completer<void>? nextStart;

  @override
  Future<RuntimeStatus> start({
    required String config,
    required String mode,
    String perAppMode = 'off',
    List<String> perAppPackages = const [],
  }) async {
    modes.add(mode);
    final decoded = jsonDecode(config) as Map<String, dynamic>;
    final inbounds = decoded['inbounds'] as List;
    hasTun.add(
      inbounds.whereType<Map>().any((inbound) => inbound['type'] == 'tun'),
    );
    expect(
      inbounds.whereType<Map>().any((inbound) => inbound['type'] == 'mixed'),
      isTrue,
    );
    if (failTun && mode == 'tun') throw const RuntimeException('测试启动失败');
    final pending = nextStart;
    nextStart = null;
    await pending?.future;
    return fetchStatus();
  }

  @override
  Future<RuntimeStatus> fetchStatus() async =>
      const RuntimeStatus(running: true);

  @override
  Future<void> shutdown() async => stops++;

  @override
  Future<RuntimeTraffic> fetchTraffic() async => const RuntimeTraffic();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SystemProxy extends WindowsSystemProxy {
  _SystemProxy(super.paths);
  bool enabled = false;

  @override
  ProxyApplyResult enable(int port) {
    enabled = true;
    return const ProxyApplyResult(ok: true);
  }

  @override
  ProxyApplyResult disable() {
    enabled = false;
    return const ProxyApplyResult(ok: true);
  }
}

class _RefreshController extends _Controller {
  int refreshes = 0;

  @override
  Future<void> refreshConnectionInfo() async => refreshes++;
}

class _WireGuardConnectionController extends _Controller {
  @override
  RuntimeTestResult? wireGuardLatency;
}

class _Storage extends AppStorage {
  _Storage() : super(AppPaths.forDirectory(Directory.systemTemp.path));
  bool fail = false;
  AppSnapshot? saved;
  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (fail) throw const FileSystemException('test write failure');
    saved = AppSnapshot.fromJson(snapshot.toJson());
  }
}
