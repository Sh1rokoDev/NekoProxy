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
      'google': ServiceCheckResult(
        status: ServiceCheckStatus.available,
        latencyMs: 392,
        checkedAt: DateTime(2026, 11, 13, 13, 58),
        address: '142.251.150.119',
        addressInfo: (
          region: 'United States · Mountain View',
          countryCode: 'US',
          provider: 'Google LLC · AS15169',
        ),
      ),
      'github': const ServiceCheckResult(
        status: ServiceCheckStatus.available,
        address: '140.82.112.3',
        addressInfo: (
          region: 'Singapore',
          countryCode: 'SG',
          provider: 'Microsoft Azure',
        ),
      ),
      'youtube': const ServiceCheckResult(
        status: ServiceCheckStatus.available,
        address: '142.251.154.4',
      ),
      'chatgpt': ServiceCheckResult(
        status: ServiceCheckStatus.failed,
        error: '超时',
        checkedAt: DateTime(2026, 11, 13, 13, 59),
      ),
    });
    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(home: ServiceStatusPage()),
      ),
    );
    expect(find.text('142.251.150.119 · 392ms'), findsOneWidget);
    expect(find.text('超时'), findsOneWidget);
    final region = find.widgetWithText(RegionBadge, 'US');
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
    expect(find.widgetWithText(RegionBadge, 'SG'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\b\d{2}:\d{2}\b')), findsNothing);
    expect(find.byType(RegionBadge), findsNWidgets(3));
    expect(find.widgetWithText(RegionBadge, '未提供'), findsOneWidget);
    expect(find.text('运营商：未提供'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // A roomy viewport restores every full label together.
    tester.view.physicalSize = const Size(1280, 1000);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(RegionBadge, 'United States · Mountain View'),
      findsOneWidget,
    );
    expect(find.widgetWithText(RegionBadge, 'Singapore'), findsOneWidget);
    expect(find.widgetWithText(RegionBadge, 'SG'), findsNothing);

    for (final width in [320.0, 390.0, 428.0]) {
      tester.view.physicalSize = Size(width, 1000);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(RegionBadge, 'US'), findsOneWidget);
      expect(find.widgetWithText(RegionBadge, 'SG'), findsOneWidget);
      final badgeText = find.descendant(
        of: find.widgetWithText(RegionBadge, 'US'),
        matching: find.byType(Text),
      );
      expect(tester.widget<Text>(badgeText).maxLines, 1);
      expect(tester.takeException(), isNull, reason: 'width $width');
    }
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(RegionBadge, 'US'), findsOneWidget);
    expect(find.widgetWithText(RegionBadge, 'SG'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
