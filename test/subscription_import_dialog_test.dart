import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('导入成功后订阅弹窗正常退场', (tester) async {
    final controller = await _startImport(tester);
    const subscriptionName = '测试订阅';
    controller.result.complete(
      Subscription(
        id: 'test-subscription',
        name: subscriptionName,
        url: _subscriptionUrl,
        nodes: [
          ProxyNode(
            id: 'test-node',
            tag: 'test-node',
            name: '测试节点',
            subscriptionId: 'test-subscription',
            outbound: const {'type': 'direct'},
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(subscriptionName), findsOneWidget);
    expect(find.text('测试节点'), findsOneWidget);
    expect(find.text('订阅已导入'), findsOneWidget);
  });

  testWidgets('请求失败后可以重试，关闭弹窗后不再更新界面', (tester) async {
    final controller = await _startImport(tester);
    controller.result.completeError(const FormatException('订阅响应无效'));
    await tester.pumpAndSettle();
    expect(find.textContaining('订阅响应无效'), findsOneWidget);

    controller.result = Completer<Subscription>();
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();

    controller.result.completeError(const FormatException('订阅请求超时'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('暂无节点'), findsOneWidget);
  });
}

const _subscriptionUrl = 'https://example.com/sub';

Future<_ImportController> _startImport(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final controller = _ImportController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(NekoProxyApp(controller: controller));
  await tester.tap(find.text('节点').hitTestable());
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FloatingActionButton, '添加'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('订阅分组'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField).first, _subscriptionUrl);
  await tester.tap(find.widgetWithText(FilledButton, '导入'));
  await tester.pump();
  expect(find.byType(LinearProgressIndicator), findsOneWidget);
  return controller;
}

class _ImportController extends AppController {
  var result = Completer<Subscription>();

  @override
  Future<Subscription> importFromUrl({
    required String url,
    String? name,
    String userAgent = '',
  }) async {
    final subscription = await result.future;
    snapshot.subscriptions.add(subscription);
    notifyListeners();
    return subscription;
  }
}
