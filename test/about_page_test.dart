import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/widgets.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/features/tools/about_page.dart';
import 'package:nekoproxy/services/app_update_service.dart';
import 'package:nekoproxy/state/app_controller.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('关于页显示应用图标并并排显示开源协议和许可证入口', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'NekoProxy',
      packageName: 'nekoproxy',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: AboutPage(coreVersion: 'v1.14.4')),
      phase: EnginePhase.paint,
    );
    expect(
      find.image(const AssetImage('assets/icons/app_icon.png')),
      findsOneWidget,
    );
    expect(find.text('隐私'), findsNothing);
    expect(find.text('开源与致谢'), findsNothing);
    expect(find.text('许可证'), findsNothing);
    expect(find.text('本地端口'), findsNothing);

    double rightEdgeOf(String value) {
      final render = tester
          .state<EditableTextState>(find.text(value))
          .renderEditable;
      final end = render.getLocalRectForCaret(
        TextPosition(offset: value.length),
      );
      return render.localToGlobal(end.topLeft).dx;
    }

    expect(
      rightEdgeOf('sing-box 1.14.4'),
      closeTo(rightEdgeOf('Flutter · Material 3'), 0.01),
    );

    final section = find.widgetWithText(SectionCard, '开源协议');
    final license = find.descendant(
      of: section,
      matching: find.text('GPL-3.0-or-later'),
    );
    final button = find.descendant(of: section, matching: find.text('查看开源许可证'));
    expect(
      tester.getCenter(button).dx,
      greaterThan(tester.getCenter(license).dx),
    );
    expect(
      tester.getCenter(button).dy,
      closeTo(tester.getCenter(license).dy, 1),
    );

    await tester.tap(button);
    await tester.pump(Duration.zero, EnginePhase.paint);
    await tester.pump(const Duration(milliseconds: 350), EnginePhase.paint);
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('进入关于页自动检查一次，检查进度与右侧按钮并排', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'NekoProxy',
      packageName: 'nekoproxy',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _UpdateController();
    addTearDown(controller.dispose);
    final page = AppScope(
      controller: controller,
      child: const MaterialApp(home: AboutPage()),
    );

    await tester.pumpWidget(page, phase: EnginePhase.paint);
    await tester.pump(Duration.zero, EnginePhase.paint);
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(controller.checks, 1);

    final button = find.widgetWithText(TextButton, '检查更新');
    final progress = find.byType(LinearProgressIndicator);
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    final buttonRect = tester.getRect(button);
    final progressRect = tester.getRect(progress);
    final titleRect = tester.getRect(find.text('应用更新'));
    expect(buttonRect.top, greaterThan(titleRect.bottom));
    expect(buttonRect.left, greaterThan(progressRect.right));
    expect(buttonRect.top, lessThan(progressRect.center.dy));
    expect(buttonRect.bottom, greaterThan(progressRect.center.dy));

    controller.result.complete(null);
    await tester.pump(Duration.zero, EnginePhase.paint);
    final statusRect = tester.getRect(find.text('没有可用的新版本。'));
    final settledButtonRect = tester.getRect(button);
    expect(settledButtonRect.left, greaterThan(statusRect.right));
    expect(settledButtonRect.center.dy, closeTo(statusRect.center.dy, 1));
    expect(controller.checks, 1);

    await tester.tap(button);
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(controller.checks, 2);

    await tester.pumpWidget(const SizedBox.shrink(), phase: EnginePhase.paint);
    await tester.pumpWidget(page, phase: EnginePhase.paint);
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(controller.checks, 3);
  }, skip: !Platform.isWindows && !Platform.isAndroid);

  testWidgets('更新检查出现未知异常时显示兜底提示', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'NekoProxy',
      packageName: 'nekoproxy',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _FailingUpdateController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(home: AboutPage(coreVersion: 'v1.14.4')),
      ),
      phase: EnginePhase.paint,
    );
    await tester.pump(Duration.zero, EnginePhase.paint);
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(find.text('更新操作失败，请稍后重试。'), findsOneWidget);
  }, skip: !Platform.isWindows && !Platform.isAndroid);
}

class _UpdateController extends AppController {
  _UpdateController() {
    paths = AppPaths.forDirectory(Directory.systemTemp.path);
  }

  final result = Completer<AppUpdate?>();
  int checks = 0;

  @override
  AppUpdateService createUpdateService() => _UpdateService(this);
}

class _UpdateService extends AppUpdateService {
  _UpdateService(this.controller)
    : super(() => throw StateError('Unexpected HTTP client'));

  final _UpdateController controller;

  @override
  Future<AppUpdate?> check(String currentVersion, UpdatePackageKind kind) {
    controller.checks++;
    return controller.result.future;
  }
}

class _FailingUpdateController extends AppController {
  _FailingUpdateController() {
    paths = AppPaths.forDirectory(Directory.systemTemp.path);
  }

  @override
  AppUpdateService createUpdateService() => _FailingUpdateService();
}

class _FailingUpdateService extends AppUpdateService {
  _FailingUpdateService()
    : super(() => throw StateError('Unexpected HTTP client'));

  @override
  Future<AppUpdate?> check(
    String currentVersion,
    UpdatePackageKind kind,
  ) async {
    throw Exception('Unexpected update failure');
  }
}
