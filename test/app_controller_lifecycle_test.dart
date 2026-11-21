import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('启动失败可重试，同一时刻只初始化一次', () async {
    final directory = await Directory.systemTemp.createTemp('neko-start-');
    addTearDown(() => directory.delete(recursive: true));
    final paths = _FailingPaths(AppPaths.forDirectory(directory.path));
    final controller = AppController();
    addTearDown(controller.dispose);

    final first = controller.initialize(appPaths: paths);
    expect(controller.initialize(appPaths: paths), same(first));
    await expectLater(first, throwsA(isA<FileSystemException>()));
    expect(controller.initialized, isFalse);
    expect(controller.appearanceTick.value, 0);

    paths.fail = false;
    await controller.initialize(appPaths: paths);
    expect(controller.initialized, isTrue);
    expect(controller.paths, same(paths));
    expect(controller.appearanceTick.value, 1);
    await controller.initialize(appPaths: paths);
    expect(controller.appearanceTick.value, 1);
  });

  test('启动结果尚未就绪时退出，不访问未赋值的核心', () async {
    final directory = await Directory.systemTemp.createTemp('neko-exit-');
    addTearDown(directory.delete);
    final paths = AppPaths.forDirectory(directory.path);
    final controller = AppController();
    addTearDown(controller.dispose);

    final startup = controller.initialize(appPaths: paths);
    await controller.shutdownForExit();
    await startup;
    expect(controller.initialized, isFalse);
    expect(controller.appearanceTick.value, 0);
  });

  test('恢复与重置仅在保存成功后更新主题和强调色', () async {
    final storage = _MemoryStorage();
    final controller = _AppearanceController()..storage = storage;
    addTearDown(controller.dispose);
    controller.settings.theme = ThemePreference.light;
    final restored = AppSnapshot.empty();
    restored.settings
      ..theme = ThemePreference.dark
      ..seedColor = 0xFF222299;
    final backup = jsonEncode({
      'app': 'nekoproxy',
      'version': 2,
      'data': restored.toJson(),
    });
    final observed = <(ThemePreference, int)>[];
    controller.appearanceTick.addListener(() {
      observed.add((controller.settings.theme, controller.settings.seedColor));
    });

    storage.fail = true;
    await expectLater(controller.importBackup(backup), throwsStateError);
    expect(observed, isEmpty);
    expect(controller.settings.theme, ThemePreference.light);

    storage.fail = false;
    await controller.importBackup(backup);
    await controller.resetAll();
    expect(observed, [
      (ThemePreference.dark, restored.settings.seedColor),
      (ThemePreference.system, AppSettings().seedColor),
    ]);
  });
}

class _FailingPaths extends AppPaths {
  _FailingPaths(AppPaths paths)
    : super(base: paths.base, runtime: paths.runtime, logFile: paths.logFile);

  bool fail = true;

  @override
  File get proxySnapshotFile {
    if (fail) throw const FileSystemException('模拟初始化中断');
    return super.proxySnapshotFile;
  }
}

class _AppearanceController extends AppController {
  @override
  Future<void> disconnect({bool silent = false}) async {}
}

class _MemoryStorage extends AppStorage {
  _MemoryStorage() : super(AppPaths.forDirectory('.'));

  bool fail = false;

  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (fail) throw StateError('模拟保存失败');
  }
}
