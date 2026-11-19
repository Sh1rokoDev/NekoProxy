import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/tools/tools_page.dart';
import 'package:nekoproxy/runtime/android_runtime.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('安卓常规设置可切换并保存 CPU 唤醒锁', (tester) async {
    final paths = AppPaths.forDirectory('.');
    final storage = _MemoryStorage(paths);
    final controller = _AndroidController()
      ..storage = storage
      ..runtime = AndroidRuntimeClient(paths);
    addTearDown(controller.dispose);
    const channel = MethodChannel('nekoproxy/runtime');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final applied = <bool>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setCpuWakeLockEnabled');
      applied.add(call.arguments as bool);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(home: Scaffold(body: ToolsPage())),
      ),
    );
    final label = find.text('获取 CPU 唤醒锁');
    expect(find.text('代理运行时保持 CPU 唤醒，可能增加耗电'), findsNothing);
    final y = tester.getCenter(label).dy;
    expect(y, greaterThan(tester.getCenter(find.text('启动时自动连接')).dy));
    expect(y, lessThan(tester.getCenter(find.text('规则集自动更新')).dy));
    expect(AppSettings.fromJson({}).cpuWakeLockEnabled, isFalse);

    for (final enabled in [true, false]) {
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(controller.settings.cpuWakeLockEnabled, enabled);
      expect(storage.saved?.settings.cpuWakeLockEnabled, enabled);
    }
    expect(applied, [true, false]);
  });

  testWidgets('其他平台不显示 CPU 唤醒锁开关', (tester) async {
    final controller = _NonAndroidController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(home: Scaffold(body: ToolsPage())),
      ),
    );
    expect(find.text('获取 CPU 唤醒锁'), findsNothing);
  });
}

class _AndroidController extends AppController {
  @override
  bool get isAndroid => true;
}

class _NonAndroidController extends AppController {
  @override
  bool get isAndroid => false;
}

class _MemoryStorage extends AppStorage {
  _MemoryStorage(super.paths);

  AppSnapshot? saved;

  @override
  Future<void> save(AppSnapshot snapshot) async {
    saved = AppSnapshot.fromJson(snapshot.toJson());
  }
}
