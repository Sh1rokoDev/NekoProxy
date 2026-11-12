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
import 'package:nekoproxy/services/exit_info_service.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
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
    Rect cardBounds(HomeCard card) =>
        tester.getRect(find.byKey(ValueKey(card)));
    final modeBounds = cardBounds(HomeCard.splitMode);
    final trafficBounds = cardBounds(HomeCard.traffic);
    final subscriptionBounds = cardBounds(HomeCard.subscription);
    expect(modeBounds.top, trafficBounds.top);
    expect(modeBounds.left, greaterThan(trafficBounds.right));
    expect(modeBounds.width, lessThan(trafficBounds.width));
    expect(modeBounds.width, subscriptionBounds.width);
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
      tester.getTopLeft(infoStrip).dy,
      greaterThan(tester.getTopLeft(find.text('还没有节点')).dy),
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

  testWidgets('未连接卡片将状态与模式并入顶部信息行，出口提示保持单行且高度紧凑', (tester) async {
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
    expect(find.byKey(const ValueKey('connection-info-strip')), findsOneWidget);
    expect(find.text('连接后检测出口信息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('连接卡片宽屏横排，窄屏出口信息分为两行两列', (tester) async {
    final node = ProxyNode(
      id: 'node',
      tag: 'node',
      name: '香港实验性 IEPL 专线 1',
      outbound: {'server': 'example.net', 'server_port': 10011},
      subscriptionId: 'sub',
    );
    final controller = _Controller()
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
    final title = inCard(node.name);
    final mode = inCard('自动选择');
    final status = inCard('已连接');
    final ip = inCard('192.0.2.1');
    final address = inCard('example.net:10011');
    final region = inCard('Japan · Tokyo');
    void expectSingleLineIpAndBadgeBeforeAddress() {
      final editable = tester
          .state<EditableTextState>(
            find.descendant(
              of: connectionCard,
              matching: find.byType(EditableText),
            ),
          )
          .renderEditable;
      expect(editable.size.height, closeTo(editable.preferredLineHeight, 1));
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
    expect(inCard('断开连接'), findsOneWidget);
    expect(tester.getTopLeft(title).dy, lessThan(tester.getRect(power).bottom));
    expect(tester.getCenter(mode).dy, closeTo(tester.getCenter(status).dy, 3));
    final wideHeadingY = tester.getCenter(inCard('出口 IP')).dy;
    for (final title in ['运营商', '节点延迟', '来源']) {
      expect(tester.getCenter(inCard(title)).dy, closeTo(wideHeadingY, 2));
    }
    expectSingleLineIpAndBadgeBeforeAddress();
    for (final value in ['示例运营商', '47ms', 'sub.example.net']) {
      expect(
        tester.getCenter(inCard(value)).dy,
        closeTo(tester.getCenter(ip).dy, 2),
      );
    }
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(400, 1000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(inCard('断开连接'), findsNothing);
    expect(find.byTooltip('断开连接'), findsOneWidget);
    expect(
      tester.getTopLeft(mode).dy,
      greaterThan(tester.getRect(address).bottom),
    );
    final exit = tester.getTopLeft(inCard('出口 IP'));
    final provider = tester.getTopLeft(inCard('运营商'));
    final latency = tester.getTopLeft(inCard('节点延迟'));
    final source = tester.getTopLeft(inCard('来源'));
    expect(provider.dy, closeTo(exit.dy, 2));
    expect(provider.dx, greaterThan(exit.dx));
    expect(latency.dy, greaterThan(tester.getRect(ip).bottom));
    expect(latency.dy, source.dy);
    expect(latency.dx, exit.dx);
    expect(provider.dx, source.dx);
    expectSingleLineIpAndBadgeBeforeAddress();
    final addressText = tester.renderObject<RenderParagraph>(address);
    expect(
      addressText.size.width,
      lessThan(addressText.getMaxIntrinsicWidth(double.infinity)),
    );
    expect(tester.widget<Text>(address).overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页切换规则模式会保存并更新连接卡片，保存失败时恢复原模式', (tester) async {
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
    expect(find.text('全局代理'), findsOneWidget);

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
    await tester.pump(const Duration(milliseconds: 600));
    final editor = find.ancestor(
      of: find.text('编辑桌面首页'),
      matching: find.byType(SectionCard),
    );
    final subscriptionRow = find
        .ancestor(
          of: find.descendant(of: editor, matching: find.text('订阅用量')),
          matching: find.byType(Row),
        )
        .first;
    await tester.tap(
      find.descendant(of: subscriptionRow, matching: find.byType(Checkbox)),
    );
    await tester.tap(find.byTooltip('上移订阅用量'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(HomeSubscriptionCard), findsNothing);
    await tester.tap(find.byTooltip('完成编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(storage.saved, isNotNull);
    expect(
      storage.saved!.settings.homeDesktop.hidden,
      contains(HomeCard.subscription),
    );
    final order = storage.saved!.settings.homeDesktop.order;
    expect(
      order.indexOf(HomeCard.subscription),
      lessThan(order.indexOf(HomeCard.traffic)),
    );
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
    await tester.tap(find.byTooltip('上移订阅用量'));
    await tester.tap(find.byTooltip('完成编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('首页布局保存失败，请重试'), findsOneWidget);
    expect(find.byTooltip('完成编辑'), findsOneWidget);
    expect(controller.settings.homeDesktop.order, HomeCard.values);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byTooltip('编辑首页'), findsOneWidget);
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
      expect(find.text('编辑手机首页'), findsOneWidget);
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
