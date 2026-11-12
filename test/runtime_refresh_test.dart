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
    expect(controller.liveTick.value, 0);
  });
}

class _DelayedRuntime implements RuntimeClient {
  final connections = Completer<List<RuntimeConnection>>();

  @override
  Future<List<RuntimeConnection>> fetchConnections() => connections.future;

  @override
  Future<void> shutdown() async {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
