import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;
import 'package:nekoproxy/app/theme.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/rules/installed_apps_dialog.dart';
import 'package:nekoproxy/runtime/android_runtime.dart';
import 'package:nekoproxy/runtime/runtime_client.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('应用图标按需加载并可在搜索时复用', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const runtimeChannel = MethodChannel('nekoproxy/runtime');
    const iconChannel = MethodChannel('nekoproxy/app_icons');
    final firstIcon = Completer<Uint8List>();
    final requested = <String>[];
    messenger.setMockMethodCallHandler(runtimeChannel, (call) async {
      if (call.method == 'requestAppListPermission') return null;
      expect(call.method, 'apps');
      return [
        {'package': 'app.alpha', 'label': 'Alpha'},
        {'package': 'app.beta', 'label': 'Beta'},
        for (var index = 0; index < 100; index++)
          {'package': 'app.other$index', 'label': 'Other $index'},
      ];
    });
    messenger.setMockMethodCallHandler(iconChannel, (call) async {
      expect(call.method, 'load');
      expect(call.arguments['size'], 96);
      final packageName = call.arguments['package'] as String;
      requested.add(packageName);
      if (packageName == 'app.alpha') return firstIcon.future;
      if (packageName == 'app.beta') {
        throw PlatformException(code: 'app_icon_error');
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(runtimeChannel, null);
      messenger.setMockMethodCallHandler(iconChannel, null);
    });
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    final controller = AppController()
      ..runtime = AndroidRuntimeClient(AppPaths.forDirectory('.'));
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light, Colors.blue),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => pickInstalledApps(context, controller, const []),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    Finder iconOf(String packageName, Type type) => find.descendant(
      of: find.byKey(ValueKey(packageName)),
      matching: find.byType(type),
    );

    expect(iconOf('app.alpha', CircleAvatar), findsOneWidget);
    expect(iconOf('app.beta', CircleAvatar), findsOneWidget);
    expect(requested, containsAll(['app.alpha', 'app.beta']));
    expect(requested, isNot(contains('app.other99')));

    final search = find.byType(TextField);
    await tester.tap(search);
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pumpAndSettle();
    final searchLabel = tester.getRect(find.text('搜索应用名或包名'));
    final scrollArea = tester.getRect(find.byType(CustomScrollView));
    expect(searchLabel.top, greaterThanOrEqualTo(scrollArea.top));
    expect(find.widgetWithText(OutlinedButton, '全选'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '反选'), findsOneWidget);
    expect(
      tester.getRect(find.text('已选 0 个')).right,
      closeTo(tester.getRect(search).right, 0.01),
    );
    expect(tester.takeException(), isNull);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();

    await tester.enterText(search, ' APP.BETA ');
    await tester.pumpAndSettle();
    final png = images.encodePng(images.Image(width: 96, height: 96));
    firstIcon.complete(png);
    await tester.pumpAndSettle();
    expect(iconOf('app.beta', CircleAvatar), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);

    await tester.enterText(search, 'Alpha');
    await tester.pumpAndSettle();
    final icon = iconOf('app.alpha', Image);
    final image = tester.widget<Image>(icon);
    expect((image.image as MemoryImage).bytes, png);
    await tester.runAsync(
      () => precacheImage(image.image, tester.element(icon)),
    );
    await tester.pump();
    final rendered = tester.widget<RawImage>(iconOf('app.alpha', RawImage));
    expect(rendered.image?.width, 96);
    expect(requested.where((packageName) => packageName == 'app.alpha'), [
      'app.alpha',
    ]);
  });

  testWidgets('应用列表等待系统授权，拒绝后可重试', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const channel = MethodChannel('nekoproxy/runtime');
    final firstRequest = Completer<void>();
    var requests = 0;
    var queries = 0;
    const permissionHint = '请在系统设置中允许 NekoProxy 获取应用列表，然后重试。';
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'requestAppListPermission') {
        if (++requests == 1) {
          await firstRequest.future;
          throw PlatformException(
            code: 'apps_permission',
            message: permissionHint,
          );
        }
        return null;
      }
      expect(call.method, 'apps');
      queries++;
      return <Object?>[];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final controller = AppController()
      ..runtime = AndroidRuntimeClient(AppPaths.forDirectory('.'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => pickInstalledApps(context, controller, const []),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(requests, 1);
    expect(queries, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    firstRequest.complete();
    await tester.pumpAndSettle();
    expect(find.text('读取应用列表失败：$permissionHint'), findsOneWidget);
    expect(queries, 0);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(queries, 1);
    expect(find.text('没有读取到可启动的应用。'), findsOneWidget);
  });

  testWidgets('VPN 应用过滤沿用已有设置，保存失败可重试并可重新连接', (tester) async {
    final storage = _MemoryStorage();
    final controller = _VpnController()
      ..storage = storage
      ..running = true;
    controller.settings
      ..perAppMode = PerAppMode.block
      ..perAppPackages = ['app.example'];
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light, Colors.blue),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showVpnAppFilter(context, controller),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final label = tester.getRect(find.text('VPN 接管范围'));
    final scrollArea = tester.getRect(find.byType(CustomScrollView));
    expect(label.top, greaterThanOrEqualTo(scrollArea.top));
    expect(find.widgetWithText(OutlinedButton, '全选'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '反选'), findsOneWidget);
    expect(
      tester.getRect(find.text('已选 1 个')).right,
      closeTo(tester.getRect(find.byType(TextField)).right, 0.01),
    );
    expect(find.text('排除所选'), findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    await tester.tap(find.text('反选'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.settings.perAppPackages, ['app.example']);

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('排除所选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('代理所选').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('反选'));
    await tester.pumpAndSettle();
    expect(find.text('至少选择一个应用，否则无法连接。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    storage.fail = true;
    await tester.tap(find.text('保存并重新连接'));
    await tester.pumpAndSettle();
    expect(find.text('无法应用设置，请重试。'), findsOneWidget);
    expect(controller.settings.perAppMode, PerAppMode.block);
    expect(controller.restarts, 0);

    storage.fail = false;
    await tester.tap(find.text('保存并重新连接'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.settings.perAppMode, PerAppMode.allow);
    expect(controller.settings.perAppPackages, ['app.example']);
    expect(controller.restarts, 1);
  });
}

class _VpnController extends AppController {
  int restarts = 0;

  @override
  Future<void> restartCore() async => restarts++;

  @override
  Future<List<InstalledApp>> installedApps() async => const [
    InstalledApp(packageName: 'app.example', label: 'Example'),
  ];

  @override
  Future<Uint8List?> installedAppIcon(String packageName, int size) async =>
      null;
}

class _MemoryStorage extends AppStorage {
  _MemoryStorage() : super(AppPaths.forDirectory('.'));

  bool fail = false;

  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (fail) throw StateError('保存失败');
  }
}
