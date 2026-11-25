import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/app_shell.dart';
import 'package:nekoproxy/app/navigation_dock.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/config_compiler.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/nodes/node_group_widgets.dart';
import 'package:nekoproxy/features/nodes/nodes_page.dart';
import 'package:nekoproxy/runtime/runtime_client.dart';
import 'package:nekoproxy/services/rule_set_manager.dart';
import 'package:nekoproxy/services/qr_service.dart';
import 'package:nekoproxy/state/app_controller.dart';
import 'package:zxing2/qrcode.dart';

final _key = base64Encode(List.filled(32, 2));
String get _configuration =>
    '''
[Interface]
PrivateKey = $_key
Address = 10.0.0.2/24
[Peer]
PublicKey = $_key
Endpoint = 192.0.2.1:53
AllowedIPs = 0.0.0.0/0
''';

class _MemoryStorage extends AppStorage {
  _MemoryStorage(super.paths);
  bool fail = false;
  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (fail) throw const FileSystemException('save failed');
  }
}

class _ConfPicker extends FilePickerPlatform {
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    expect(allowedExtensions, ['conf']);
    return [_ConfFile()];
  }
}

final class _ConfFile extends PlatformFile {
  @override
  String get name => '文件配置.conf';

  @override
  Future<Uint8List> readAsBytes() async => utf8.encode(_configuration);

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppController _newController({bool withProxy = false}) {
  final paths = AppPaths.forDirectory(Directory.systemTemp.path);
  final controller = AppController()
    ..paths = paths
    ..storage = _MemoryStorage(paths)
    ..ruleSets = RuleSetManager(paths: paths, clientFactory: HttpClient.new);
  if (withProxy) {
    final snapshot = controller.snapshot;
    snapshot.subscriptions.add(
      Subscription(
        id: 'local',
        name: '代理分组',
        nodes: [
          for (final id in ['a', 'b'])
            ProxyNode(
              id: id,
              tag: id,
              name: '代理 $id',
              subscriptionId: 'local',
              outbound: {
                'type': 'http',
                'server': '192.0.2.5',
                'server_port': 8080,
              },
            ),
        ],
      ),
    );
    snapshot.settings.manualNodeId = 'a';
  }
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _openNodes(WidgetTester tester, AppController controller) =>
    tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextField, label);

WireGuardProfile _profile(String id) =>
    WireGuardProfile(id: id, name: '隧道 $id', configuration: _configuration);

void main() {
  for (final axis in Axis.values) {
    testWidgets('$axis 导航随 sing-box 和 WireGuard 切换伸缩并渐变', (tester) async {
      final vertical = axis == Axis.vertical;
      tester.view.physicalSize = Size(vertical ? 1024 : 390, 680);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _newController(withProxy: true);
      await controller.saveWireGuardGroup('校园', id: WireGuardGroup.legacy.id);
      await controller.saveWireGuardProfile(_profile('a'));
      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(controller: controller, child: const AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      final dock = find.byType(NavigationDock);
      Finder tab(String label) =>
          find.descendant(of: dock, matching: find.text(label));
      final rules = tab('规则');
      double extent() {
        final size = tester.getSize(dock);
        return vertical ? size.height : size.width;
      }

      double rulesOpacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: rules,
                  matching: find.descendant(
                    of: dock,
                    matching: find.byType(Opacity),
                  ),
                )
                .first,
          )
          .opacity;

      final fullExtent = extent();
      final buttonExtent = vertical ? 58 : 72;
      final reducedExtent = fullExtent - buttonExtent;
      expect(fullExtent, 8 + 4 * buttonExtent);
      await _tap(tester, rules);
      await controller.selectWireGuard('a');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      expect(tester.widget<NavigationDock>(dock).selected, 0);
      expect(extent(), inExclusiveRange(reducedExtent, fullExtent));
      expect(rulesOpacity(), inExclusiveRange(0, 1));
      await tester.tap(rules);
      expect(tester.widget<NavigationDock>(dock).selected, 0);
      await tester.pumpAndSettle();
      expect(extent(), reducedExtent);
      expect(rules, findsNothing);

      await controller.selectNode('b');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      expect(extent(), inExclusiveRange(reducedExtent, fullExtent));
      expect(rulesOpacity(), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(extent(), fullExtent);
      expect(rulesOpacity(), 1);
    });
  }

  test('WireGuard QR image decodes and validates as a configuration', () async {
    final matrix = Encoder.encode(
      _configuration,
      ErrorCorrectionLevel.m,
    ).matrix!;
    const border = 4;
    final raster = image.Image(
      width: matrix.width + 2 * border,
      height: matrix.height + 2 * border,
    );
    image.fill(raster, color: image.ColorRgb8(255, 255, 255));
    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        if (matrix.get(x, y) == 1) {
          raster.setPixelRgb(x + border, y + border, 0, 0, 0);
        }
      }
    }
    final png = image.encodePng(
      image.copyResize(raster, width: raster.width * 4),
    );
    final decoded = await decodeQrFromImageBytes(png);
    expect(decoded, _configuration);
    expect(WireGuardConfig.parse(decoded ?? '').firstEndpoint, '192.0.2.1:53');
  });

  testWidgets(
    'creates a group, writes a .conf and edits the saved fields without selecting it',
    (tester) async {
      final controller = _newController();
      await _openNodes(tester, controller);
      await _tap(tester, find.text('添加'));
      await _tap(tester, find.text('WireGuard 分组'));
      await tester.enterText(_field('分组名称'), '校园');
      await _tap(tester, find.text('保存'));
      final addButton = find.widgetWithText(TextButton, '添加节点');
      expect(find.widgetWithText(NodeGroupEmpty, '暂无节点'), findsOneWidget);
      expect(addButton, findsOneWidget);
      await _tap(tester, addButton);
      expect(find.text('从剪贴板导入'), findsOneWidget);
      expect(find.text('从文件导入'), findsOneWidget);
      expect(find.text('从二维码图片导入'), findsOneWidget);
      await _tap(tester, find.text('单个节点'));
      await _tap(tester, find.text('编写 .conf'));
      await tester.enterText(_field('名称'), '手写配置');
      await tester.enterText(_field('WireGuard 配置'), _configuration);
      await _tap(tester, find.text('保存节点'));
      expect(
        controller.snapshot.wireGuardProfiles.single.groupId,
        controller.snapshot.wireGuardGroups.single.id,
      );
      expect(controller.snapshot.wireGuardProfileId, isNull);

      await _tap(tester, find.byTooltip('配置操作：手写配置'));
      expect(find.byIcon(Icons.code_rounded), findsOneWidget);
      expect(find.byIcon(Icons.file_download_outlined), findsOneWidget);
      expect(find.byType(PopupMenuDivider), findsOneWidget);
      await _tap(tester, find.text('编辑节点'));
      await tester.ensureVisible(_field('对端地址（Endpoint）'));
      await tester.enterText(_field('对端地址（Endpoint）'), '[2001:db8::1]:51820');
      expect(tester.widget<TextField>(_field('私钥')).obscureText, isTrue);
      await _tap(tester, find.text('保存节点'));
      expect(
        controller.snapshot.wireGuardProfiles.single.parse().firstEndpoint,
        '[2001:db8::1]:51820',
      );
      expect(find.text('[2001:db8::1]:51820'), findsOneWidget);
    },
  );

  testWidgets('creates a WireGuard node with fields', (tester) async {
    final controller = _newController();
    await controller.saveWireGuardGroup('校园', id: WireGuardGroup.legacy.id);
    await _openNodes(tester, controller);
    await _tap(tester, find.widgetWithText(TextButton, '添加节点'));
    await _tap(tester, find.text('单个节点'));
    await _tap(tester, find.text('使用表单'));
    for (final entry in {
      '名称': '表单配置',
      '私钥': _key,
      '本地地址（Address）': '10.0.0.2/24',
      '对端公钥': _key,
      '对端地址（Endpoint）': 'vpn.example.com:53',
      '允许的网段（AllowedIPs）': '0.0.0.0/0',
    }.entries) {
      await tester.ensureVisible(_field(entry.key));
      await tester.enterText(_field(entry.key), entry.value);
      await tester.pump();
    }
    await _tap(tester, find.text('保存节点'));
    final profile = controller.snapshot.wireGuardProfiles.single;
    expect(profile.name, '表单配置');
    expect(find.text('vpn.example.com:53'), findsOneWidget);
  });

  testWidgets(
    'WireGuard uses the same grid and collapse behavior as proxy groups',
    (tester) async {
      final controller = _newController(withProxy: true);
      await controller.saveWireGuardGroup('校园', id: WireGuardGroup.legacy.id);
      await controller.saveWireGuardProfile(_profile('a'));
      await controller.saveWireGuardProfile(_profile('b'));
      await _openNodes(tester, controller);

      final proxy = find.widgetWithText(NodeTile, '代理 a');
      final tunnel = find.widgetWithText(NodeTile, '隧道 a');
      // The active group has a slightly thicker border.
      expect(
        tester.getSize(tunnel).width,
        closeTo(tester.getSize(proxy).width, 1),
      );
      expect(tester.getSize(tunnel).height, tester.getSize(proxy).height);
      expect(
        tester.getTopLeft(tunnel).dy,
        tester.getTopLeft(find.widgetWithText(NodeTile, '隧道 b')).dy,
      );
      expect(find.text('WireGuard · 2 节点'), findsOneWidget);
      expect(
        find.descendant(of: tunnel, matching: find.text('192.0.2.1:53')),
        findsOneWidget,
      );

      await _tap(tester, find.text('校园'));
      expect(tunnel, findsNothing);
      expect(proxy, findsOneWidget);
      await _tap(tester, find.text('校园'));
      await _tap(tester, find.text('隧道 a'));
      expect(controller.activeWireGuard?.id, 'a');
      expect(tester.widget<NodeTile>(tunnel).current, isTrue);
    },
  );

  testWidgets(
    'WireGuard-only nodes can test a group, a node and all nodes offline',
    (tester) async {
      final runtime = _WireGuardTestRuntime();
      final controller = _newController()..runtime = runtime;
      await controller.saveWireGuardGroup('校园', id: WireGuardGroup.legacy.id);
      await controller.saveWireGuardProfile(_profile('a'));
      await controller.saveWireGuardProfile(
        WireGuardProfile(
          id: 'b',
          name: '隧道 b',
          configuration: _configuration.replaceFirst(':53', ':54'),
        ),
      );
      await _openNodes(tester, controller);
      Finder inNode(String id, Finder matching) => find.descendant(
        of: find.widgetWithText(NodeTile, '隧道 $id'),
        matching: matching,
      );

      expect(inNode('a', find.text('—')), findsOneWidget);
      await _tap(tester, find.byTooltip('测试本组 WireGuard 节点'));
      expect(runtime.ports, [53, 54]);
      expect(inNode('a', find.text('41ms')), findsOneWidget);
      expect(inNode('b', find.text('失败')), findsOneWidget);
      expect(inNode('b', find.byTooltip('请求超时')), findsOneWidget);

      await _tap(tester, find.byTooltip('配置操作：隧道 a'));
      await _tap(tester, find.text('测试节点延迟'));
      expect(runtime.ports, [53, 54, 53]);
      expect(inNode('a', find.text('43ms')), findsOneWidget);

      await _tap(tester, find.byTooltip('测速所有分组节点'));
      expect(runtime.ports, [53, 54, 53, 53, 54]);
      expect(runtime.stops, 5);
      expect(controller.snapshot.wireGuardProfileId, isNull);
      expect(controller.running, isFalse);
    },
  );

  testWidgets('file and clipboard imports stay in the chosen group', (
    tester,
  ) async {
    final controller = _newController();
    await controller.saveWireGuardGroup('校园', id: WireGuardGroup.legacy.id);
    final picker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _ConfPicker();
    addTearDown(() => FilePickerPlatform.instance = picker);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': _configuration} : null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await _openNodes(tester, controller);
    final addButton = find.widgetWithText(TextButton, '添加节点');
    await _tap(tester, addButton);
    await _tap(tester, find.text('从文件导入'));
    expect(controller.snapshot.wireGuardProfiles.single.name, '文件配置');
    expect(addButton, findsNothing);
    await _tap(tester, find.byTooltip('WireGuard 分组操作'));
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
    expect(find.byType(PopupMenuDivider), findsOneWidget);
    await _tap(tester, find.text('添加 WireGuard 节点'));
    await _tap(tester, find.text('从剪贴板导入'));
    await tester.enterText(_field('名称'), '剪贴板配置');
    await _tap(tester, find.text('保存节点'));
    expect(
      controller.snapshot.wireGuardProfiles.map((profile) => profile.name),
      ['文件配置', '剪贴板配置'],
    );
    expect(
      controller.snapshot.wireGuardProfiles.every(
        (profile) => profile.groupId == WireGuardGroup.legacy.id,
      ),
      isTrue,
    );
    expect(controller.snapshot.wireGuardProfileId, isNull);
  });

  testWidgets(
    'chain switch shows both stages, restores WireGuard, and gates rules navigation',
    (tester) async {
      final controller = _newController(withProxy: true);
      await controller.saveWireGuardGroup('校园', id: WireGuardGroup.legacy.id);
      await controller.saveWireGuardProfile(_profile('a'));
      await controller.selectWireGuard('a');
      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(controller: controller, child: const AppShell()),
        ),
      );
      List<String> tabs() => tester
          .widget<NavigationDock>(find.byType(NavigationDock))
          .destinations
          .map((item) => item.label)
          .toList();
      expect(tabs(), isNot(contains('规则')));
      expect(find.text('规则模式'), findsNothing);
      await _tap(tester, find.text('节点'));
      await _tap(tester, find.byTooltip('高级'));
      await _tap(tester, find.text('启用链式代理'));
      expect(controller.outboundMode, OutboundMode.wireGuardProxy);
      expect(find.text('第一级 · WireGuard'), findsOneWidget);
      expect(find.text('第二级 · sing-box'), findsOneWidget);
      expect(find.text('隧道 a'), findsOneWidget);
      expect(find.text('代理 a'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tabs(), contains('规则'));
      final proxyTile = find.ancestor(
        of: find.text('代理 a'),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is AnimatedContainer &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color ==
                  Theme.of(tester.element(find.text('代理 a')))
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.5),
        ),
      );
      expect(proxyTile, findsOneWidget);
      await tester.ensureVisible(find.text('隧道 a'));
      expect(
        tester.widget<NodeTile>(find.widgetWithText(NodeTile, '隧道 a')).current,
        isTrue,
      );
      await _tap(tester, find.byTooltip('高级'));
      await _tap(tester, find.text('启用链式代理'));
      expect(controller.outboundMode, OutboundMode.wireGuard);
      expect(controller.snapshot.wireGuardProfileId, 'a');
      expect(tester.takeException(), isNull);
    },
  );

  test('manual and automatic proxy changes preserve the first stage and failed saves are atomic', () async {
    final controller = _newController(withProxy: true);
    await controller.saveWireGuardGroup('校园', id: WireGuardGroup.legacy.id);
    await controller.saveWireGuardProfile(_profile('a'));
    await controller.saveWireGuardProfile(_profile('b'));
    await expectLater(
      controller.setChainProxyEnabled(true),
      throwsA(isA<Exception>()),
    );
    await controller.selectWireGuard('a');
    await controller.setChainProxyEnabled(true);
    await controller.selectNode('b');
    expect(controller.settings.manualNodeId, 'b');
    expect(controller.activeWireGuard?.id, 'a');
    await controller.setSelectionMode(SelectionMode.auto);
    expect(controller.chainProxyEnabled, isTrue);
    expect(controller.snapshot.allNodes.map((node) => node.id), ['a', 'b']);
    expect(controller.compile().nodeTags.keys, ['a', 'b']);
    final storage = controller.storage as _MemoryStorage;
    storage.fail = true;
    await expectLater(
      controller.selectWireGuard('b'),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.activeWireGuard?.id, 'a');
    storage.fail = false;
    await controller.selectWireGuard('b');
    await controller.setChainProxyEnabled(false);
    expect(controller.outboundMode, OutboundMode.wireGuard);
    expect(controller.activeWireGuard?.id, 'b');
    expect(controller.settings.selectionMode, SelectionMode.auto);
    await controller.deleteWireGuardGroup(WireGuardGroup.legacy.id);
    expect(controller.canConnect, isFalse);
    expect(controller.snapshot.wireGuardProfiles, isEmpty);
  });
}

class _WireGuardTestRuntime extends RuntimeClient {
  final ports = <int>[];
  int stops = 0;

  @override
  Future<void> startTest({required String config}) async {
    final json = jsonDecode(config) as Map<String, dynamic>;
    expect(json['inbounds'], isEmpty);
    expect(json.containsKey('experimental'), isFalse);
    final endpoint = (json['endpoints'] as List).single as Map;
    expect(endpoint['tag'], ConfigCompiler.wireGuardTag);
    expect(endpoint['system'], isFalse);
    final peer = (endpoint['peers'] as List).single as Map;
    ports.add(peer['port'] as int);
  }

  @override
  Future<Map<String, RuntimeTestResult>> test(
    List<String> tags,
    String url,
  ) async {
    expect(tags, [ConfigCompiler.wireGuardTag]);
    expect(url, isNotEmpty);
    return {
      tags.single: ports.last == 54
          ? const RuntimeTestResult(error: '请求超时')
          : RuntimeTestResult(delay: 40 + ports.length),
    };
  }

  @override
  Future<void> stopTest() async => stops++;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
