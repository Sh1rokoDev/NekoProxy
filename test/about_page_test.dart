import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/features/tools/about_page.dart';
import 'package:nekoproxy/features/tools/app_update_card.dart';
import 'package:nekoproxy/services/app_update_service.dart';
import 'package:nekoproxy/state/app_controller.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _columnDivider = find.byKey(const ValueKey('about-column-divider'));

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'NekoProxy',
      packageName: 'nekoproxy',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('宽版关于页并排显示版本和项目链接，许可证入口可打开', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: AboutPage()),
      phase: EnginePhase.paint,
    );
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(
      find.image(const AssetImage('assets/icons/app_icon.png')),
      findsOneWidget,
    );
    final version = find.text('当前版本');
    final project = find.widgetWithText(ListTile, 'GitHub 仓库');
    final icon = find.image(const AssetImage('assets/icons/app_icon.png'));
    final license = find.widgetWithText(ListTile, 'GPL-3.0-or-later');
    expect(find.text('1.0.0 (1)'), findsOneWidget);
    expect(find.text('代理核心'), findsNothing);
    expect(find.text('界面'), findsNothing);
    expect(
      tester.getBottomLeft(icon).dy,
      lessThan(tester.getTopLeft(version).dy),
    );
    expect(
      tester.getTopRight(version).dx,
      lessThan(tester.getTopLeft(project).dx),
    );
    expect(
      tester.getTopLeft(project).dy,
      closeTo(tester.getTopLeft(icon).dy, 1),
    );
    final divider = tester.getRect(_columnDivider);
    expect(divider.left, greaterThan(tester.getTopRight(version).dx));
    expect(divider.right, lessThan(tester.getTopLeft(project).dx));
    expect(divider.top, tester.getTopLeft(project).dy);
    expect(
      divider.bottom,
      greaterThanOrEqualTo(tester.getBottomLeft(license).dy),
    );

    await tester.tap(license);
    await tester.pump(Duration.zero, EnginePhase.paint);
    await tester.pump(const Duration(milliseconds: 350), EnginePhase.paint);
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('GitHub 项目链接在外部浏览器打开，并提示打开失败', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = tester.binding.defaultBinaryMessenger;
    final launched = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'launch');
      expect(call.arguments['useWebView'], isFalse);
      launched.add(call.arguments['url'] as String);
      return launched.length < 3;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const MaterialApp(home: AboutPage()),
      phase: EnginePhase.paint,
    );

    for (final label in ['GitHub 仓库', '发布记录', '问题反馈']) {
      final tile = find.widgetWithText(ListTile, label);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pump(Duration.zero, EnginePhase.paint);
    }
    expect(launched, [
      'https://github.com/Sh1rokoDev/NekoProxy',
      'https://github.com/Sh1rokoDev/NekoProxy/releases',
      'https://github.com/Sh1rokoDev/NekoProxy/issues',
    ]);
    expect(find.text('无法打开链接，请稍后重试。'), findsOneWidget);
  });

  testWidgets('更新模块在窄版项目入口上方，缩放窗口时保留检查状态', (tester) async {
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

    final button = find.widgetWithText(OutlinedButton, '检查更新');
    final progress = find.byType(LinearProgressIndicator);
    final version = find.text('1.0.0 (1)');
    final project = find.widgetWithText(ListTile, 'GitHub 仓库');
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    final buttonRect = tester.getRect(button);
    final progressRect = tester.getRect(progress);
    expect(_columnDivider, findsNothing);
    expect(buttonRect.left, greaterThan(tester.getTopRight(version).dx));
    expect(progressRect.top, greaterThan(buttonRect.bottom));
    expect(progressRect.bottom, lessThan(tester.getTopLeft(project).dy));

    await tester.binding.setSurfaceSize(const Size(800, 800));
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(_columnDivider, findsOneWidget);
    expect(
      tester.getTopRight(progress).dx,
      lessThan(tester.getTopLeft(project).dx),
    );
    expect(controller.checks, 1);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    final updater = find.byType(AppUpdateCard);
    expect(
      tester.getRect(_columnDivider).bottom,
      tester.getRect(updater).bottom,
    );

    controller.result.complete(null);
    await tester.pump(Duration.zero, EnginePhase.paint);
    final status = find.text('没有可用的新版本。');
    expect(
      tester.getRect(_columnDivider).bottom,
      tester.getRect(status).bottom,
    );

    await tester.binding.setSurfaceSize(const Size(320, 800));
    await tester.pump(Duration.zero, EnginePhase.paint);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(_columnDivider, findsNothing);
    final icon = find.image(const AssetImage('assets/icons/app_icon.png'));
    expect(
      tester.getBottomLeft(icon).dy,
      lessThan(tester.getTopLeft(find.text('NekoProxy')).dy),
    );
    expect(tester.takeException(), isNull);
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pump(Duration.zero, EnginePhase.paint);

    final statusRect = tester.getRect(status);
    expect(statusRect.top, greaterThan(tester.getBottomRight(button).dy));
    expect(statusRect.bottom, lessThan(tester.getTopLeft(project).dy));
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
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _FailingUpdateController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(home: AboutPage()),
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
