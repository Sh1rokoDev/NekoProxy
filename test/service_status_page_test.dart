import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/widgets.dart';
import 'package:nekoproxy/features/status/service_status.dart';
import 'package:nekoproxy/services/connectivity_service.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('服务状态页在手机宽度显示 IP、地区、运营商及缺失提示', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController();
    addTearDown(controller.dispose);
    controller.serviceChecks.addAll({
      'google': const ServiceCheckResult(
        status: ServiceCheckStatus.available,
        latencyMs: 392,
        address: '142.251.150.119',
        addressInfo: (
          region: 'United States · Mountain View',
          provider: 'Google LLC · AS15169',
        ),
      ),
      'github': const ServiceCheckResult(
        status: ServiceCheckStatus.available,
        address: '140.82.112.3',
      ),
    });
    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(home: ServiceStatusPage()),
      ),
    );
    expect(find.textContaining('142.251.150.119 · 392ms'), findsOneWidget);
    final region = find.widgetWithText(
      RegionBadge,
      'United States · Mountain View',
    );
    final available = find.text('可用').first;
    expect(
      tester.getRect(region).left,
      greaterThan(tester.getRect(available).right),
    );
    expect(
      tester.getCenter(region).dy,
      closeTo(tester.getCenter(available).dy, 1),
    );
    expect(find.text('运营商：Google LLC · AS15169'), findsOneWidget);
    expect(find.widgetWithText(RegionBadge, '未提供'), findsOneWidget);
    expect(find.text('运营商：未提供'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
