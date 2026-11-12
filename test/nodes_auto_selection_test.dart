import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/nodes/nodes_page.dart';
import 'package:nekoproxy/runtime/runtime_client.dart';
import 'package:nekoproxy/services/rule_set_manager.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('测速按钮显示排队和完成进度，按点击顺序依次测速', (tester) async {
    final first = _node('first', '节点甲', group: 'first-group');
    final second = _node('second', '节点乙', group: 'second-group');
    final runtime = _Runtime();
    final startTest = runtime.delayedTestStart = Completer<void>();
    final controller = AppController()
      ..paths = AppPaths.forDirectory(Directory.systemTemp.path)
      ..runtime = runtime
      ..snapshot = AppSnapshot(
        settings: AppSettings(splitMode: SplitMode.global),
        subscriptions: [
          Subscription(id: 'first-group', name: '分组甲', nodes: [first]),
          Subscription(id: 'second-group', name: '分组乙', nodes: [second]),
        ],
      );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

    final groupButtons = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '测试本组节点',
    );
    final visibleButton = find.byWidgetPredicate(
      (widget) =>
          widget is FloatingActionButton && widget.heroTag == 'nodes-speed',
    );
    final addButton = find.widgetWithText(FloatingActionButton, '添加');
    Finder visibleLabel(String text) =>
        find.descendant(of: visibleButton, matching: find.text(text));
    Finder progressIn(Finder button) => find.descendant(
      of: button,
      matching: find.byType(CircularProgressIndicator),
    );

    expect(visibleLabel('测速'), findsOneWidget);
    expect(tester.getSize(visibleButton), tester.getSize(addButton));

    await tester.tap(groupButtons.first);
    await tester.pump();
    expect(progressIn(groupButtons.first), findsOneWidget);
    expect(progressIn(groupButtons.last), findsNothing);
    expect(progressIn(visibleButton), findsNothing);
    await tester.tap(groupButtons.last);
    await tester.pump();
    expect(progressIn(groupButtons.last), findsOneWidget);
    await tester.tap(visibleButton);
    await tester.pump();
    expect(progressIn(visibleButton), findsOneWidget);
    expect(visibleLabel('排队中'), findsOneWidget);
    expect(
      tester.widget<FloatingActionButton>(visibleButton).onPressed,
      isNull,
    );
    expect(tester.widget<IconButton>(groupButtons.last).onPressed, isNull);
    expect(runtime.probes, isEmpty);

    startTest.complete();
    await tester.pump();
    expect(runtime.probes.keys, ['node-first']);

    runtime.completeProbe(first.id);
    await tester.pump();
    expect(progressIn(groupButtons.first), findsOneWidget);
    expect(progressIn(groupButtons.last), findsOneWidget);
    expect(progressIn(visibleButton), findsOneWidget);
    expect(runtime.probes.keys, ['node-first', 'node-second']);

    runtime.probes.remove('node-first');
    runtime.completeProbe(second.id, delay: 70);
    runtime.probes.remove('node-second');
    await tester.pump();
    expect(progressIn(groupButtons), findsNWidgets(2));
    expect(progressIn(visibleButton), findsOneWidget);
    expect(visibleLabel('测速中 0/2'), findsOneWidget);
    expect(runtime.probes.keys, ['node-first', 'node-second']);

    runtime.completeProbe(first.id, delay: 100);
    await tester.pump();
    expect(visibleLabel('测速中 1/2'), findsOneWidget);
    expect(controller.latencies[first.id], 100);
    expect(controller.testingNodes, isTrue);

    runtime.completeProbe(second.id, delay: 80);
    await tester.pumpAndSettle();
    expect(progressIn(groupButtons), findsNothing);
    expect(progressIn(visibleButton), findsNothing);
    expect(visibleLabel('测速'), findsOneWidget);
    expect(
      tester.widget<FloatingActionButton>(visibleButton).onPressed,
      isNotNull,
    );
    expect(controller.latencies, {first.id: 100, second.id: 80});
  });

  testWidgets('全量测速包含搜索隐藏的分组，并让所有分组图标持续显示动画', (tester) async {
    final first = _node('first', '节点甲', group: 'first-group');
    final second = _node('second', '节点乙', group: 'second-group');
    final runtime = _Runtime();
    final startTest = runtime.delayedTestStart = Completer<void>();
    final controller = AppController()
      ..paths = AppPaths.forDirectory(Directory.systemTemp.path)
      ..runtime = runtime
      ..snapshot = AppSnapshot(
        settings: AppSettings(splitMode: SplitMode.global),
        subscriptions: [
          Subscription(id: 'first-group', name: '分组甲', nodes: [first]),
          Subscription(id: 'second-group', name: '分组乙', nodes: [second]),
        ],
      );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

    final groupButtons = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '测试本组节点',
    );
    final allButton = find.byWidgetPredicate(
      (widget) =>
          widget is FloatingActionButton && widget.heroTag == 'nodes-speed',
    );
    Finder groupProgress() => find.descendant(
      of: groupButtons,
      matching: find.byType(CircularProgressIndicator),
    );

    await tester.tap(find.byTooltip('搜索节点'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '节点甲');
    await tester.pump();
    expect(groupButtons, findsOneWidget);

    await tester.tap(allButton);
    await tester.pump();
    expect(groupProgress(), findsOneWidget);
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pump();
    expect(groupButtons, findsNWidgets(2));
    expect(groupProgress(), findsNWidgets(2));
    for (final button in tester.widgetList<IconButton>(groupButtons)) {
      expect(button.onPressed, isNull);
    }

    startTest.complete();
    await tester.pump();
    expect(runtime.probes.keys, ['node-first', 'node-second']);
    expect(groupProgress(), findsNWidgets(2));

    runtime.completeProbe(first.id, delay: 50);
    await tester.pump();
    expect(controller.testCompleted, 1);
    expect(groupProgress(), findsNWidgets(2));

    runtime.completeProbe(second.id);
    await tester.pumpAndSettle();
    expect(groupProgress(), findsNothing);
    expect(controller.testingNodes, isFalse);
    for (final button in tester.widgetList<IconButton>(groupButtons)) {
      expect(button.onPressed, isNotNull);
    }
  });

  testWidgets('节点卡片的状态提示各有独立的无障碍节点', (tester) async {
    final node = _node('node', '节点')
      ..favorite = true
      ..autoEnabled = false;
    final runtime = _Runtime();
    final controller = AppController()
      ..paths = AppPaths.forDirectory(Directory.systemTemp.path)
      ..runtime = runtime
      ..snapshot = AppSnapshot(
        settings: AppSettings(splitMode: SplitMode.global),
        subscriptions: [
          Subscription(id: 'main', name: '主分组', nodes: [node]),
        ],
      )
      ..latencyErrors = {node.id: '测速失败'};
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

    int tooltipNodeId(String message) {
      final semanticsNode = tester.getSemantics(find.byTooltip(message));
      expect(semanticsNode.getSemanticsData().tooltip, message);
      return semanticsNode.id;
    }

    final errorId = tooltipNodeId('测速失败');
    final favoriteId = tooltipNodeId('已收藏');
    final autoId = tooltipNodeId('已移出自动候选');
    expect({errorId, favoriteId, autoId}, hasLength(3));

    controller.queueNodeTest([node]);
    await tester.pump();
    runtime.completeProbe(node.id, delay: 80);
    await tester.pumpAndSettle();

    expect(find.byTooltip('测速失败'), findsNothing);
    expect(tooltipNodeId('已收藏'), favoriteId);
    expect(tooltipNodeId('已移出自动候选'), autoId);
  });

  test('延迟测试最多并发 32 个，单个完成后立即回传并补充下一个', () async {
    final nodes = [
      for (var index = 0; index < 33; index++)
        _node('batch-$index', '节点$index'),
    ];
    final runtime = _Runtime();
    final controller = AppController()
      ..paths = AppPaths.forDirectory(Directory.systemTemp.path)
      ..runtime = runtime
      ..snapshot = AppSnapshot(
        settings: AppSettings(splitMode: SplitMode.global),
        subscriptions: [Subscription(id: 'main', name: '主分组', nodes: nodes)],
      );
    addTearDown(controller.dispose);

    final run = controller.testNodes();
    await _waitUntil(() => runtime.probes.length == 32);
    expect(runtime.batchSizes, List.filled(32, 1));

    runtime.completeProbe(nodes[7].id, delay: 50);
    await _waitUntil(() => runtime.probes.length == 33);
    expect(runtime.batchSizes, List.filled(33, 1));
    expect(controller.testCompleted, 1);
    expect(controller.latencies, {nodes[7].id: 50});
    expect(controller.testingNodes, isTrue);

    runtime.completeProbe(nodes.last.id, delay: 40);
    await _waitUntil(() => controller.testCompleted == 2);
    for (final node in nodes.take(32).where((node) => node != nodes[7])) {
      runtime.completeProbe(node.id, delay: 50);
    }
    await run;
    expect(controller.testCompleted, 33);
    expect(controller.latencies, hasLength(33));
  });

  test('少于 32 个节点时成功、失败和请求异常均立即回传', () async {
    final nodes = [
      for (var index = 0; index < 3; index++) _node('$index', '节点$index'),
    ];
    final runtime = _Runtime();
    final controller = AppController()
      ..paths = AppPaths.forDirectory(Directory.systemTemp.path)
      ..runtime = runtime
      ..snapshot = AppSnapshot(
        settings: AppSettings(splitMode: SplitMode.global),
        subscriptions: [Subscription(id: 'main', name: '主分组', nodes: nodes)],
      );
    addTearDown(controller.dispose);

    final run = controller.testNodes();
    await _waitUntil(() => runtime.probes.length == 3);
    runtime.completeProbe(nodes[1].id);
    await _waitUntil(() => controller.testCompleted == 1);
    expect(controller.latencyErrors[nodes[1].id], '测速失败');
    expect(controller.testingNodes, isTrue);

    runtime.completeProbe(nodes[2].id, delay: 70);
    await _waitUntil(() => controller.testCompleted == 2);
    expect(controller.latencies, {nodes[2].id: 70});
    expect(controller.testingNodes, isTrue);

    runtime.probes['node-${nodes[0].id}']!.completeError(
      const RuntimeException('控制连接已关闭'),
    );
    await run;
    expect(controller.testCompleted, 3);
    expect(controller.latencyErrors[nodes[0].id], contains('控制连接已关闭'));
    expect(controller.testingNodes, isFalse);
  });

  test('取消测速后丢弃迟到结果并停止调度剩余节点', () async {
    final nodes = [
      for (var index = 0; index < 33; index++) _node('$index', '节点$index'),
    ];
    final runtime = _Runtime();
    final controller = AppController()
      ..paths = AppPaths.forDirectory(Directory.systemTemp.path)
      ..runtime = runtime
      ..snapshot = AppSnapshot(
        settings: AppSettings(splitMode: SplitMode.global),
        subscriptions: [Subscription(id: 'main', name: '主分组', nodes: nodes)],
      );

    final run = controller.testNodes();
    await _waitUntil(() => runtime.probes.length == 32);
    controller.dispose();
    for (final node in nodes.take(32)) {
      runtime.completeProbe(node.id, delay: 50);
    }
    await run;
    expect(runtime.probes, hasLength(32));
    expect(controller.testCompleted, 0);
    expect(controller.latencies, isEmpty);
  });

  testWidgets('自动节点高亮随离线测速和核心状态切换', (tester) async {
    final first = _node('first', '节点甲');
    final second = _node('second', '节点乙');
    final disabled = _node('disabled', '禁用节点')..autoEnabled = false;
    final disabledGroupNode = _node(
      'disabled-group',
      '禁用分组节点',
      group: 'disabled',
    );
    final snapshot = AppSnapshot(
      settings: AppSettings(
        manualNodeId: disabled.id,
        selectionMode: SelectionMode.auto,
        splitMode: SplitMode.global,
      ),
      subscriptions: [
        Subscription(id: 'main', name: '主分组', nodes: [first, second, disabled]),
        Subscription(
          id: 'disabled',
          name: '禁用分组',
          autoEnabled: false,
          nodes: [disabledGroupNode],
        ),
      ],
    );
    final runtime = _Runtime();
    final paths = AppPaths(
      base: Directory('test'),
      runtime: Directory('test'),
      logFile: File('test/runtime.log'),
    );
    final controller = AppController()
      ..paths = paths
      ..storage = _Storage(paths)
      ..runtime = runtime
      ..ruleSets = RuleSetManager(paths: paths, clientFactory: HttpClient.new)
      ..snapshot = snapshot;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

    void expectHighlight(String name, bool highlighted) {
      final node = find.text(name);
      final colors = Theme.of(tester.element(node)).colorScheme;
      final cards = tester.widgetList<AnimatedContainer>(
        find.ancestor(of: node, matching: find.byType(AnimatedContainer)),
      );
      expect(
        cards.any(
          (card) =>
              (card.decoration as BoxDecoration?)?.color ==
              colors.primaryContainer.withValues(alpha: 0.5),
        ),
        highlighted,
      );
    }

    final selectionStatus = find.textContaining(
      RegExp(r'离线推荐|当前节点 ·|暂无核心选点状态|测速中，等待可用结果'),
    );
    expect(selectionStatus, findsNothing);
    expectHighlight('禁用节点', false);
    final test = controller.testNodes();
    await tester.pump();
    expect(selectionStatus, findsNothing);

    runtime.completeProbe(first.id, delay: 100);
    await tester.pump();
    expect(selectionStatus, findsNothing);
    expectHighlight('节点甲', false);

    runtime.completeProbe(second.id, delay: 70);
    runtime.completeProbe(disabled.id, delay: 30);
    runtime.completeProbe(disabledGroupNode.id, delay: 20);
    await tester.pump();
    await test;
    expect(selectionStatus, findsNothing);
    expectHighlight('节点乙', true);
    expectHighlight('节点甲', false);

    final connect = controller.connect();
    await tester.pump();
    await connect;
    expect(selectionStatus, findsNothing);
    expectHighlight('节点甲', false);
    expectHighlight('节点乙', false);

    runtime.selected = 'node-${first.id}';
    await tester.pump(const Duration(seconds: 1));
    expect(selectionStatus, findsNothing);
    expectHighlight('节点甲', true);
    expectHighlight('节点乙', false);
    final groupTitle = find.text('主分组');
    final groupCard = tester.widget<AnimatedContainer>(
      find.ancestor(of: groupTitle, matching: find.byType(AnimatedContainer)),
    );
    final colors = Theme.of(tester.element(groupTitle)).colorScheme;
    expect(
      (groupCard.decoration as BoxDecoration?)?.border,
      Border.all(color: colors.outlineVariant.withValues(alpha: 0.35)),
    );

    final previousStatus = await runtime.fetchStatus();
    final delayedStatus = runtime.delayedStatus = Completer<RuntimeStatus>();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(runtime.delayedStatus, isNull);

    runtime.probes.clear();
    final connectedTest = controller.testNodes(
      nodes: [first, second, disabled],
    );
    runtime.completeProbe(first.id, delay: 240);
    runtime.completeProbe(disabled.id);
    await tester.pump();
    expect(runtime.autoRefreshes, isEmpty);
    expectHighlight('节点甲', true);
    runtime.completeProbe(second.id, delay: 75);
    await tester.pump();
    await connectedTest;
    expect(runtime.autoRefreshes, [
      {'node-first': 240, 'node-second': 75, 'node-disabled': null},
    ]);
    expect(selectionStatus, findsNothing);
    await tester.pump();
    expectHighlight('节点乙', true);
    delayedStatus.complete(previousStatus);
    await tester.pump();
    expectHighlight('节点乙', true);
    expectHighlight('节点甲', false);

    final disconnect = controller.disconnect();
    await tester.pump();
    await disconnect;
    expect(selectionStatus, findsNothing);
    expectHighlight('节点乙', true);

    runtime.probes.clear();
    final retest = controller.testNodes(nodes: [second]);
    await tester.pump();
    runtime.completeProbe(second.id);
    await tester.pump();
    await retest;
    expect(selectionStatus, findsNothing);
    expectHighlight('节点乙', false);
  });
}

ProxyNode _node(String id, String name, {String group = 'main'}) => ProxyNode(
  id: id,
  tag: id,
  name: name,
  subscriptionId: group,
  outbound: const {
    'type': 'trojan',
    'server': 'example.com',
    'server_port': 443,
    'password': 'test',
  },
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('条件在等待时间内未满足');
}

class _Storage extends AppStorage {
  _Storage(super.paths);

  @override
  Future<void> save(AppSnapshot snapshot) async {}
}

class _Runtime extends RuntimeClient {
  final probes = <String, Completer<RuntimeTestResult>>{};
  final autoRefreshes = <Map<String, int?>>[];
  final batchSizes = <int>[];
  Completer<void>? delayedTestStart;
  Completer<RuntimeStatus>? delayedStatus;
  String selected = '';

  void completeProbe(String id, {int? delay}) {
    probes
        .putIfAbsent('node-$id', Completer.new)
        .complete(
          RuntimeTestResult(delay: delay, error: delay == null ? '测速失败' : null),
        );
  }

  @override
  Future<Map<String, RuntimeTestResult>> test(
    List<String> tags,
    String url,
  ) async {
    batchSizes.add(tags.length);
    final results = await Future.wait([
      for (final tag in tags)
        probes
            .putIfAbsent(tag, Completer.new)
            .future
            .then((result) => MapEntry(tag, result)),
    ]);
    return Map.fromEntries(results);
  }

  @override
  Future<void> startTest({required String config}) async {
    final delayed = delayedTestStart;
    delayedTestStart = null;
    await delayed?.future;
  }

  @override
  Future<void> stopTest() async {}

  @override
  Future<RuntimeStatus> start({
    required String config,
    required String mode,
    String perAppMode = 'off',
    List<String> perAppPackages = const [],
  }) => fetchStatus();

  @override
  Future<RuntimeStatus> fetchStatus() async {
    final delayed = delayedStatus;
    delayedStatus = null;
    if (delayed != null) return delayed.future;
    return RuntimeStatus(
      running: true,
      groups: {
        'auto': RuntimeGroup(kind: 'urltest', selected: selected, all: []),
      },
    );
  }

  @override
  Future<void> refreshAuto(Map<String, int?> delays) async {
    autoRefreshes.add(Map.of(delays));
    int? bestDelay;
    for (final MapEntry(key: tag, value: delay) in delays.entries) {
      if (delay != null && (bestDelay == null || delay < bestDelay)) {
        selected = tag;
        bestDelay = delay;
      }
    }
  }

  @override
  Future<RuntimeTraffic> fetchTraffic() async => const RuntimeTraffic();

  @override
  Future<List<RuntimeConnection>> fetchConnections() async => [];

  @override
  Future<void> shutdown() async {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
