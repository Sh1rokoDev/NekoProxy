import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/config_compiler.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/domain/profile_parser.dart';
import 'package:nekoproxy/runtime/runtime_client.dart';
import 'package:nekoproxy/services/rule_set_manager.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  late AppController controller;
  late String url;
  late StreamIterator<HttpRequest> requests;
  const nodeLink = 'trojan://test-password@example.com:443#Node';

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('neko-sub-');
    addTearDown(() => directory.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    requests = StreamIterator(server);
    addTearDown(requests.cancel);
    url = 'http://127.0.0.1:${server.port}/subscription';
    controller = AppController()
      ..storage = AppStorage(AppPaths.forDirectory(directory.path));
    addTearDown(controller.dispose);
    controller.snapshot.subscriptions.addAll([
      Subscription(id: 'first', name: '节点集合'),
      Subscription(id: 'target', name: '订阅', url: url),
      Subscription(id: 'last', name: '另一个集合'),
    ]);
  });

  Future<HttpRequest> nextRequest() async {
    expect(await requests.moveNext(), isTrue);
    return requests.current;
  }

  Future<void> respond(HttpRequest request, String body) async {
    request.response.write(body);
    await request.response.close();
  }

  test('前面的分组被删除后，更新仍写入目标订阅', () async {
    final update = controller.updateSubscription('target');
    final request = await nextRequest();
    await controller.deleteSubscription('first');
    await respond(request, nodeLink);
    await update;

    final groups = controller.snapshot.subscriptions;
    expect(groups.map((group) => group.id), ['target', 'last']);
    expect(groups.first.nodes.single.name, 'Node');
    expect(groups.last.nodes, isEmpty);
  }, skip: !Platform.isWindows);

  test('目标订阅被删除后，响应不能恢复该订阅', () async {
    final update = controller.updateSubscription('target');
    final request = await nextRequest();
    await controller.deleteSubscription('target');
    await respond(request, nodeLink);
    await update;

    expect(controller.snapshot.subscriptions.map((group) => group.id), [
      'first',
      'last',
    ]);
    expect(controller.notice, isNull);
  }, skip: !Platform.isWindows);

  test('旧链接失败后，错误不能覆盖新链接的更新结果', () async {
    final oldUpdate = controller.updateSubscription('target');
    final oldRequest = await nextRequest();
    await controller.updateSubscriptionInfo(
      'target',
      name: '新订阅',
      url: '$url/new',
      userAgent: '',
    );
    final newUpdate = controller.updateSubscription('target');
    await respond(await nextRequest(), nodeLink);
    await newUpdate;
    await respond(oldRequest, 'invalid response');
    await oldUpdate;

    final target = controller.snapshot.subscriptions[1];
    expect(target.url, '$url/new');
    expect(target.nodes.single.name, 'Node');
    expect(target.lastError, isNull);
    expect(controller.error, isNull);
  }, skip: !Platform.isWindows);

  test('更新响应不会覆盖用户设置的自动更新周期', () async {
    final target = controller.snapshot.subscriptions[1]
      ..autoUpdate = true
      ..updateIntervalMinutes = 6 * 60;
    final update = controller.updateSubscription('target');
    final request = await nextRequest();
    request.response.headers.set('profile-update-interval', '1');
    await respond(request, nodeLink);
    await update;

    expect(target.autoUpdate, isTrue);
    expect(target.updateIntervalMinutes, 6 * 60);
  }, skip: !Platform.isWindows);

  group('连接期间刷新订阅', () {
    const secondLink = 'trojan://test-password@other.example:443#Other';
    const thirdLink = 'trojan://test-password@third.example:443#Third';

    late _SubscriptionController client;
    late _RecordingRuntime core;
    late _MemoryStorage storage;
    late Subscription target;
    late ProxyNode firstNode;
    late ProxyNode secondNode;

    setUp(() {
      storage = _MemoryStorage();
      core = _RecordingRuntime();
      client = _SubscriptionController()
        ..paths = storage.paths
        ..storage = storage
        ..runtime = core
        ..ruleSets = RuleSetManager(
          paths: storage.paths,
          clientFactory: HttpClient.new,
        );
      addTearDown(client.dispose);
      target = controller.snapshot.subscriptions[1];
      firstNode = ProfileParser.parseLink(nodeLink, subscriptionId: target.id)!;
      secondNode = ProfileParser.parseLink(
        secondLink,
        subscriptionId: target.id,
      )!;
      target.nodes = [firstNode, secondNode];
      client.snapshot.subscriptions.add(target);
      client.settings
        ..inbound = InboundSettings(localPort: Uri.parse(url).port)
        ..manualNodeId = firstNode.id;
    });

    Future<void> refresh(String response, {String? userInfo}) async {
      final update = client.updateSubscription(target.id, silent: true);
      final request = await nextRequest();
      if (userInfo != null) {
        request.response.headers.set('subscription-userinfo', userInfo);
      }
      await respond(request, response);
      await update;
      expect(target.lastError, isNull);
    }

    test('节点相同或仅流量和到期时间变化时保存数据并保持连接', () async {
      await client.connect();
      // The startup config still has the old default after a hot switch.
      await client.selectNode(secondNode.id);
      final originalConnection = client.connectedAt;

      await refresh('$nodeLink\n$secondLink');
      final updated = target.lastUpdated;
      expect(updated, isNotNull);
      await refresh(
        '$nodeLink\n$secondLink',
        userInfo: 'upload=12; download=34; total=56; expire=1900000000',
      );

      final saved = storage.saved!.subscriptions.single;
      expect(saved.uploadBytes, 12);
      expect(saved.downloadBytes, 34);
      expect(saved.totalBytes, 56);
      expect(saved.expireAt?.millisecondsSinceEpoch, 1900000000000);
      expect(saved.lastUpdated!.isBefore(updated!), isFalse);
      expect(core.starts, 1);
      expect(core.stops, 0);
      expect(client.connectedAt, originalConnection);
      expect(client.reportedNode?.id, secondNode.id);
    });

    test('仅重命名时更新活动连接显示名称', () async {
      await client.connect();
      final tag = ConfigCompiler.nodeTag(firstNode);

      await refresh(
        '${nodeLink.replaceFirst('#Node', '#Renamed')}\n$secondLink',
      );

      expect(client.nodeNameForOutboundTag(tag), 'Renamed');
      expect(client.reportedNode?.name, 'Renamed');
      expect(core.starts, 1);
      expect(core.stops, 0);
    });

    test('上游 detour 和 domain_resolver 字段变化时保留已有节点', () async {
      await client.connect();

      await refresh(
        jsonEncode([
          {
            ...firstNode.outbound,
            'tag': firstNode.name,
            'detour': 'upstream-outbound',
            'domain_resolver': 'upstream-dns',
          },
          {...secondNode.outbound, 'tag': secondNode.name},
        ]),
      );

      expect(target.nodes.first.id, firstNode.id);
      expect(
        storage.saved!.subscriptions.single.nodes.first.outbound['detour'],
        'upstream-outbound',
      );
      expect(core.starts, 1);
      expect(core.stops, 0);
      expect(client.reportedNode?.id, firstNode.id);
    });

    test('未选中节点变化后应用新 selector，保留手动选择及规则', () async {
      client.snapshot.rules.add(
        RoutingRule(
          id: 'manual-rule',
          name: '手动分流',
          kind: RuleKind.domain,
          value: 'example.test',
          target: RuleTarget.manualGroup,
        ),
      );
      firstNode.favorite = true;
      firstNode.autoEnabled = false;
      await client.connect();

      await refresh('$nodeLink\n$thirdLink');

      expect(core.starts, 2);
      expect(core.stops, 1);
      expect(client.running, isTrue);
      expect(client.reportedNode?.id, firstNode.id);
      expect(client.reportedNode?.favorite, isTrue);
      expect(client.reportedNode?.autoEnabled, isFalse);
      expect(core.selectorMembers, [
        ConfigCompiler.nodeTag(firstNode),
        ConfigCompiler.nodeTag(target.nodes.last),
      ]);
      expect(core.routeRules.last['outbound'], ConfigCompiler.proxyTag);
      await client.selectNode(target.nodes.last.id);
      expect(client.reportedNode?.server, 'third.example');
      expect(core.starts, 2);
    });

    test('同组新请求收到相同内容时仍应用旧请求已写入但未加载的节点', () async {
      await client.connect();
      final saved = Completer<void>();
      final release = Completer<void>();
      storage.beforeNextSave = () {
        saved.complete();
        return release.future;
      };

      final oldUpdate = client.updateSubscription(target.id, silent: true);
      await respond(await nextRequest(), '$nodeLink\n$thirdLink');
      await saved.future;
      final newUpdate = client.updateSubscription(target.id, silent: true);
      final newRequest = await nextRequest();
      release.complete();
      await oldUpdate;
      expect(core.starts, 1);
      await respond(newRequest, '$nodeLink\n$thirdLink');
      await newUpdate;

      expect(core.starts, 2);
      expect(core.stops, 1);
      expect(core.selectorMembers, target.nodes.map(ConfigCompiler.nodeTag));
    });

    test('手动选中的节点被移除时断开并提示重新选择', () async {
      await client.connect();

      await refresh(secondLink);

      expect(core.starts, 1);
      expect(core.stops, 1);
      expect(client.running, isFalse);
      expect(client.settings.manualNodeId, isNull);
      expect(client.error, contains('原选中节点已从订阅移除'));
    });

    test('自动模式继续运行，历史手动节点被移除时保持自动选点和分组规则', () async {
      client.settings.selectionMode = SelectionMode.auto;
      client.snapshot.rules.add(
        RoutingRule(
          id: 'manual-rule',
          name: '手动分流',
          kind: RuleKind.domain,
          value: 'example.test',
          target: RuleTarget.manualGroup,
        ),
      );
      await client.connect();

      await refresh(secondLink);

      expect(core.starts, 2);
      expect(core.stops, 1);
      expect(client.running, isTrue);
      expect(client.settings.manualNodeId, isNull);
      expect(client.settings.selectionMode, SelectionMode.auto);
      expect(client.reportedNode?.id, secondNode.id);
      expect(core.selectorMembers, [ConfigCompiler.nodeTag(secondNode)]);
      expect(core.routeRules.last['outbound'], ConfigCompiler.proxyTag);
      expect(client.error, isNull);
    });

    test('高级出站覆盖后生成的自动分组路由发生变化时仍重新加载', () async {
      client.settings.selectionMode = SelectionMode.auto;
      secondNode.autoEnabled = false;
      client.snapshot.advancedJson = {
        'outbounds': [
          {'type': 'direct', 'tag': 'direct', 'connect_timeout': '10s'},
          {
            'type': 'selector',
            'tag': ConfigCompiler.proxyTag,
            'outbounds': ['direct'],
          },
          {
            'type': 'urltest',
            'tag': ConfigCompiler.autoTag,
            'outbounds': ['direct'],
          },
        ],
      };
      client.snapshot.rules.add(
        RoutingRule(
          id: 'auto-rule',
          name: '自动分流',
          kind: RuleKind.domain,
          value: 'example.test',
          target: RuleTarget.autoGroup,
        ),
      );
      await client.connect();
      expect(core.routeRules.last['outbound'], ConfigCompiler.autoTag);

      await refresh(secondLink);

      expect(core.starts, 2);
      expect(core.stops, 1);
      expect(client.running, isTrue);
      expect(core.routeRules.last['outbound'], ConfigCompiler.proxyTag);
    });

    for (final mode in ['custom', 'extension', 'wireguard']) {
      test('$mode 模式保存真实节点变化，保持现有连接', () async {
        const outbounds = [
          {'type': 'direct', 'tag': 'direct'},
        ];
        const route = {'final': 'direct'};
        const dns = {
          'servers': [
            {'type': 'local', 'tag': 'local'},
          ],
          'final': 'local',
        };
        if (mode == 'custom') {
          client.snapshot
            ..useCustomConfig = true
            ..customConfig = jsonEncode({
              'outbounds': outbounds,
              'route': route,
            });
        } else if (mode == 'extension') {
          client.snapshot.advancedJson = {
            'outbounds': outbounds,
            'route': route,
            'dns': dns,
          };
        } else {
          final key = base64Encode(List<int>.filled(32, 1));
          final profile = WireGuardProfile(
            id: 'wireguard',
            name: '隧道',
            configuration:
                '''
[Interface]
PrivateKey = $key
Address = 10.0.0.2/32
[Peer]
PublicKey = $key
Endpoint = 192.0.2.1:51820
AllowedIPs = 0.0.0.0/0
''',
          );
          client.snapshot
            ..outboundMode = OutboundMode.wireGuard
            ..wireGuardProfileId = profile.id
            ..wireGuardProfiles = [profile];
        }
        await client.connect();
        expect(client.running, isTrue, reason: client.error);

        await refresh(thirdLink);

        expect(client.running, isTrue);
        expect(core.starts, 1);
        expect(core.stops, 0);
        expect(client.settings.manualNodeId, isNull);
        expect(client.error, isNull);
        expect(
          storage.saved!.subscriptions.single.nodes.single.server,
          'third.example',
        );
      });
    }
  });

  test('持续收到小块数据也会在总时限内中止，保留旧节点', () async {
    final client = AppController(
      subscriptionDownloadTimeout: const Duration(milliseconds: 500),
    )..storage = _MemoryStorage();
    addTearDown(client.dispose);
    final target = Subscription(
      id: 'target',
      name: '订阅',
      url: url,
      nodes: [
        ProxyNode(
          id: 'old',
          tag: 'old',
          name: '原节点',
          outbound: const {'type': 'direct'},
        ),
      ],
    );
    client.snapshot.subscriptions.add(target);
    final update = client.updateSubscription(target.id);
    final request = await nextRequest();
    final response = request.response..bufferOutput = false;
    response.write(nodeLink);
    await response.flush();
    var chunks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      response.write('\n');
      chunks++;
    });
    try {
      await update.timeout(const Duration(seconds: 3));
    } finally {
      timer.cancel();
      await response.close();
    }
    expect(chunks, greaterThan(1));
    expect(target.nodes.single.id, 'old');
    expect(target.lastUpdated, isNull);
    expect(target.lastError, contains('订阅下载超时'));
  });
}

class _MemoryStorage extends AppStorage {
  _MemoryStorage() : super(AppPaths.forDirectory('.'));

  AppSnapshot? saved;
  Future<void> Function()? beforeNextSave;

  @override
  Future<void> save(AppSnapshot snapshot) async {
    final captured = AppSnapshot.fromJson(snapshot.toJson());
    final wait = beforeNextSave;
    beforeNextSave = null;
    if (wait != null) await wait();
    saved = captured;
  }
}

class _SubscriptionController extends AppController {
  @override
  Future<void> refreshExitInfo() async {}
}

class _RecordingRuntime extends Fake implements RuntimeClient {
  Map<String, dynamic>? _config;
  String? _manualTag;
  int starts = 0;
  int stops = 0;

  Iterable<Map<String, dynamic>> get _outbounds =>
      (_config!['outbounds'] as List).cast<Map<String, dynamic>>();

  List<String> get selectorMembers =>
      _group(ConfigCompiler.proxyTag)?.all ?? const [];

  List<Map<String, dynamic>> get routeRules =>
      (_config!['route']['rules'] as List).cast<Map<String, dynamic>>();

  RuntimeGroup? _group(String tag) {
    final outbound = _outbounds
        .where((entry) => entry['tag'] == tag)
        .firstOrNull;
    if (outbound == null) return null;
    final members = (outbound['outbounds'] as List).cast<String>();
    return RuntimeGroup(
      kind: outbound['type'] as String,
      selected:
          (tag == ConfigCompiler.proxyTag ? _manualTag : null) ??
          outbound['default'] as String? ??
          members.first,
      all: members,
    );
  }

  @override
  Future<List<String>> systemDnsServers() async => [];

  @override
  Future<RuntimeStatus> fetchStatus() async => RuntimeStatus(
    running: _config != null,
    groups: {
      if (_config != null)
        for (final tag in [ConfigCompiler.proxyTag, ConfigCompiler.autoTag])
          tag: ?_group(tag),
    },
  );

  @override
  Future<RuntimeStatus> start({
    required String config,
    required String mode,
    String perAppMode = 'off',
    List<String> perAppPackages = const [],
  }) async {
    starts++;
    _config = jsonDecode(config) as Map<String, dynamic>;
    _manualTag = null;
    return fetchStatus();
  }

  @override
  Future<void> select(String tag) async {
    if (!selectorMembers.contains(tag)) {
      throw const RuntimeException('节点未加载到 selector');
    }
    _manualTag = tag;
  }

  @override
  Future<Map<String, RuntimeTestResult>> test(
    List<String> tags,
    String url,
  ) async => {};

  @override
  Future<void> shutdown() async {
    stops++;
    _config = null;
  }
}
