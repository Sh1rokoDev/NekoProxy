import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app.dart';
import 'package:nekoproxy/app/navigation_dock.dart';
import 'package:nekoproxy/features/home/home_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1240, 800)]) {
    testWidgets('首页通知在 ${size.width} 宽度下只在底部弹出', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = _NotificationController()..loadWarning = '启动警告';
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        NekoProxyApp(controller: controller),
        phase: EnginePhase.paint,
      );
      await _pumpTransition(tester);

      void expectNotification(String message) {
        final snackBar = find.byType(SnackBar);
        expect(
          find.descendant(of: snackBar, matching: find.text(message)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(HomePage),
            matching: find.text(message),
          ),
          findsNothing,
        );
        expect(
          tester.getBottomLeft(snackBar).dy,
          greaterThan(size.height - 150),
        );
      }

      expectNotification('启动警告');
      controller.reportError('操作失败');
      controller.reportNotice('操作完成');

      final messenger = tester.state<ScaffoldMessengerState>(
        find.byType(ScaffoldMessenger),
      );
      messenger.hideCurrentSnackBar();
      await _pumpTransition(tester);
      expectNotification('操作失败');

      messenger.hideCurrentSnackBar();
      await _pumpTransition(tester);
      expectNotification('操作完成');

      await tester.pump(const Duration(seconds: 4), EnginePhase.paint);
      await _pumpTransition(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('操作完成'), findsNothing);
    });
  }

  testWidgets('规则集更新结果在当前页面弹出，相同结果可以再次显示', (tester) async {
    final controller = _NotificationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      NekoProxyApp(controller: controller),
      phase: EnginePhase.paint,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationDock),
        matching: find.text('更多'),
      ),
    );
    await _pumpTransition(tester);
    final ruleSets = find.widgetWithText(ListTile, '规则集');
    await tester.ensureVisible(ruleSets);
    await _pumpTransition(tester);
    await tester.tap(ruleSets);
    await _pumpTransition(tester);

    final snackBar = find.byType(SnackBar);
    for (var check = 0; check < 2; check++) {
      await tester.tap(find.text('检查更新'));
      await _pumpTransition(tester);
      expect(
        find.descendant(of: snackBar, matching: find.text('规则集已是最新。')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4), EnginePhase.paint);
      await _pumpTransition(tester);
      expect(snackBar, findsNothing);
    }

    controller.failRuleSetUpdate = true;
    await tester.tap(find.text('检查更新'));
    await _pumpTransition(tester);
    expect(
      find.descendant(of: snackBar, matching: find.text('规则集检查失败')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.text('规则集检查失败'),
      ),
      findsNothing,
    );
  });
}

Future<void> _pumpTransition(WidgetTester tester) async {
  // Keep these layout checks below compositing, which crashes the Windows test runner.
  await tester.pump(Duration.zero, EnginePhase.paint);
  await tester.pump(const Duration(milliseconds: 350), EnginePhase.paint);
  await tester.pump(const Duration(milliseconds: 350), EnginePhase.paint);
}

class _NotificationController extends AppController {
  bool failRuleSetUpdate = false;

  void reportError(String message) {
    error = message;
    notifyListeners();
  }

  void reportNotice(String message) {
    notice = message;
    notifyListeners();
  }

  @override
  Future<void> updateRuleSets({bool automatic = false}) async {
    if (failRuleSetUpdate) {
      ruleSetError = '规则集检查失败';
      notifyListeners();
    } else {
      reportNotice('规则集已是最新。');
    }
  }
}
