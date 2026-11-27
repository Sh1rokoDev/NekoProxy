import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nekoproxy/app/app.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/sliding_segmented_control.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/tools/tools_page.dart';
import 'package:nekoproxy/runtime/android_runtime.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  test('旧设置和无效的界面缩放使用默认值，合法档位可以往返保存', () {
    expect(AppSettings.fromJson({}).uiScalePercent, 100);
    for (final value in [0, 126, 101, '115']) {
      expect(
        AppSettings.fromJson({'uiScalePercent': value}).uiScalePercent,
        100,
      );
    }
    final settings = AppSettings(uiScalePercent: 115);
    expect(AppSettings.fromJson(settings.toJson()).uiScalePercent, 115);
  });

  testWidgets('主题入口打开居中弹窗，深浅、强调色和缩放保存并更新应用', (tester) async {
    final storage = _MemoryStorage(AppPaths.forDirectory('.'));
    final controller = _NonAndroidController()..storage = storage;
    addTearDown(controller.dispose);
    await tester.pumpWidget(NekoProxyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();

    final button = find.widgetWithText(TextButton, '主题');
    final buttonWidth = tester.getSize(button).width;
    await tester.tap(button);
    await tester.pumpAndSettle();

    final dialog = find.byType(Dialog);
    final panel = find
        .descendant(of: dialog, matching: find.byType(Material))
        .first;
    final navigator = find.byType(Navigator);
    final pageCenter = tester.getCenter(navigator);
    final pageWidth = tester.getSize(navigator).width;
    expect(tester.getCenter(panel), pageCenter);
    expect(tester.getSize(panel).width, lessThan(400));
    expect(tester.getSize(panel).height, lessThan(260));
    final mode = find.byType(SlidingSegmentedControl<ThemePreference>);
    final modeControl = tester.widget<SlidingSegmentedControl<ThemePreference>>(
      mode,
    );
    expect(modeControl.selected, ThemePreference.system);
    expect(modeControl.axis, Axis.horizontal);
    for (final icon in [
      Icons.settings_brightness_outlined,
      Icons.light_mode_outlined,
      Icons.dark_mode_outlined,
    ]) {
      expect(
        find.descendant(of: mode, matching: find.byIcon(icon)),
        findsOneWidget,
      );
    }
    final swatchRow = tester.getCenter(find.bySemanticsLabel('青')).dy;
    for (final name in ['青', '蓝', '紫', '红', '绿']) {
      final swatch = find.bySemanticsLabel(name);
      expect(swatch, findsOneWidget);
      expect(tester.getCenter(swatch).dy, swatchRow);
    }
    for (final name in ['靛', '玫红', '橙', '橄榄', '石墨']) {
      expect(find.bySemanticsLabel(name), findsNothing);
    }

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(storage.saved?.settings.theme, ThemePreference.dark);
    expect(Theme.of(tester.element(panel)).brightness, Brightness.dark);

    await tester.tap(find.bySemanticsLabel('蓝'));
    await tester.pumpAndSettle();
    expect(storage.saved?.settings.seedColor, 0xFF2563EB);
    expect(find.byType(Dialog), findsOneWidget);

    final slider = find.byType(Slider);
    final writes = storage.writes;
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(Offset(tester.getSize(slider).width / 2, 0));
    await tester.pump();
    expect(find.text('125%'), findsOneWidget);
    expect(storage.writes, writes);
    expect(controller.settings.uiScalePercent, 100);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(storage.writes, writes + 1);
    expect(storage.saved?.settings.uiScalePercent, 125);
    expect(MediaQuery.sizeOf(tester.element(panel)).width, pageWidth / 1.25);
    expect(tester.getCenter(panel), pageCenter);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(tester.getRect(button).width, closeTo(buttonWidth * 1.25, 0.01));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, 125);
  });

  testWidgets('窄屏放大时主题控件仍可用，保存失败可重试', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 520);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final storage = _MemoryStorage(AppPaths.forDirectory('.'))..fail = true;
    final controller = _NonAndroidController()..storage = storage;
    controller.settings
      ..uiScalePercent = 125
      ..seedColor = 0xFF4F46E5;
    addTearDown(controller.dispose);
    await tester.pumpWidget(NekoProxyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '主题'));
    await tester.pumpAndSettle();
    final mode = tester.widget<SlidingSegmentedControl<ThemePreference>>(
      find.byType(SlidingSegmentedControl<ThemePreference>),
    );
    expect(mode.axis, Axis.vertical);
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(controller.settings.theme, ThemePreference.system);
    expect(find.text('主题设置保存失败，请重试。'), findsOneWidget);

    storage.fail = false;
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(storage.saved?.settings.theme, ThemePreference.dark);
    expect(storage.saved?.settings.seedColor, 0xFF4F46E5);
    expect(find.text('主题设置保存失败，请重试。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
  int writes = 0;
  bool fail = false;

  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (fail) throw StateError('test save failure');
    writes++;
    saved = AppSnapshot.fromJson(snapshot.toJson());
  }
}
