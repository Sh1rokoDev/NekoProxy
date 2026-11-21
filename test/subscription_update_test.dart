import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
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

  @override
  Future<void> save(AppSnapshot snapshot) async {}
}
