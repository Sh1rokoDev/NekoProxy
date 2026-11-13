import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/runtime/runtime_client.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  test('断开后丢弃上一连接迟到的连接列表', () async {
    final runtime = _DelayedRuntime();
    final controller = AppController()
      ..runtime = runtime
      ..running = true;
    addTearDown(controller.dispose);

    final refresh = controller.refreshConnections();
    await controller.disconnect();
    runtime.connections.complete([
      RuntimeConnection.fromJson({'id': 'previous-session'}),
    ]);
    await refresh;

    expect(controller.running, isFalse);
    expect(controller.connections, isEmpty);
  });

  testWidgets('仅查看时轮询连接，手动刷新复用进行中的请求', (tester) async {
    final runtime = _DelayedRuntime();
    final controller = AppController()
      ..runtime = runtime
      ..running = true;
    addTearDown(controller.dispose);
    var updates = 0;
    controller.connectionUpdates.addListener(() => updates++);

    await tester.pump(const Duration(seconds: 10));
    expect(runtime.fetches, 0);
    final stop = controller.watchConnections();
    final refresh = controller.refreshConnections();
    expect(runtime.fetches, 1);
    await tester.pump(const Duration(seconds: 5));
    expect(runtime.fetches, 1);

    runtime.connections.complete([
      RuntimeConnection.fromJson({'id': 'new'}),
    ]);
    await refresh;
    expect(controller.connections.single.id, 'new');
    expect(updates, 1);
    expect(controller.liveTick.value, 0);

    runtime.connections = Completer();
    await tester.pump(const Duration(seconds: 5));
    expect(runtime.fetches, 2);
    stop();
    runtime.connections.complete([
      RuntimeConnection.fromJson({'id': 'late'}),
    ]);
    await tester.pump(const Duration(seconds: 10));
    expect(runtime.fetches, 2);
    expect(controller.connections.single.id, 'new');
    expect(updates, 1);
  });

  test('关闭全部连接后，旧快照不会覆盖新快照', () async {
    final runtime = _DelayedRuntime();
    final controller = AppController()
      ..runtime = runtime
      ..running = true;
    addTearDown(controller.dispose);

    final previous = runtime.connections;
    final refresh = controller.refreshConnections();
    runtime.connections = Completer()..complete([]);
    await controller.clearConnections();
    previous.complete([
      RuntimeConnection.fromJson({'id': 'closed'}),
    ]);
    await refresh;

    expect(runtime.fetches, 2);
    expect(controller.connections, isEmpty);
  });

  test('关闭单条连接后丢弃旧快照，保留其他连接', () async {
    final runtime = _DelayedRuntime();
    final closed = RuntimeConnection.fromJson({'id': 'closed'});
    final kept = RuntimeConnection.fromJson({'id': 'kept'});
    final controller = AppController()
      ..runtime = runtime
      ..running = true
      ..connections = [closed, kept];
    addTearDown(controller.dispose);

    final previous = runtime.connections;
    final refresh = controller.refreshConnections();
    runtime.connections = Completer()..complete([kept]);
    await controller.closeConnection(closed.id);
    previous.complete([closed, kept]);
    await refresh;

    expect(runtime.closedIds, [closed.id]);
    expect(controller.connections, [kept]);
  });
}

class _DelayedRuntime implements RuntimeClient {
  var connections = Completer<List<RuntimeConnection>>();
  int fetches = 0;
  final closedIds = <String>[];

  @override
  Future<List<RuntimeConnection>> fetchConnections() {
    fetches++;
    return connections.future;
  }

  @override
  Future<void> clearConnections() async {}

  @override
  Future<void> closeConnection(String id) async => closedIds.add(id);

  @override
  Future<void> shutdown() async {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
