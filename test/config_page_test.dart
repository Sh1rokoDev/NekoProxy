import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/widgets.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/config_compiler.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/tools/advanced_page.dart';
import 'package:nekoproxy/features/tools/config_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  test('旧配置按原有启用状态恢复，保存失败时恢复原模式和文本', () async {
    final prior = AppSnapshot.empty()
      ..advancedJson = {
        'log': {'level': 'info'},
      }
      ..customConfig = '{"outbounds":[]}';
    final storage = _MemoryStorage(fail: true);
    final controller = AppController()
      ..snapshot = AppSnapshot.fromJson(prior.toJson())
      ..storage = storage;
    addTearDown(controller.dispose);

    expect(
      controller.snapshot.advancedConfigMode,
      AdvancedConfigMode.extension,
    );
    prior.useCustomConfig = true;
    expect(
      AppSnapshot.fromJson(prior.toJson()).advancedConfigMode,
      AdvancedConfigMode.override,
    );
    await expectLater(
      controller.saveAdvancedConfig(AdvancedConfigMode.override, '{}'),
      throwsFormatException,
    );
    await expectLater(
      controller.saveAdvancedConfig(AdvancedConfigMode.off, ''),
      throwsStateError,
    );
    expect(
      controller.snapshot.toJson(),
      isNot(contains('inactiveAdvancedJson')),
    );
    expect(
      controller.snapshot.advancedConfigMode,
      AdvancedConfigMode.extension,
    );
    expect(controller.snapshot.advancedJson, prior.advancedJson);
    expect(controller.snapshot.customConfig, prior.customConfig);
  });

  testWidgets('标题栏切换扩展、覆盖和关闭，悬浮按钮应用所选模式', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController()..storage = _MemoryStorage();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: const SizedBox.shrink(),
      ),
    );
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<void>(
            builder: (_) =>
                AppScope(controller: controller, child: const ConfigPage()),
          ),
        );
    await tester.pumpAndSettle();

    final editor = find.byType(TextField);
    final format = find.text('格式化');
    final validate = find.text('校验');
    final save = find.text('保存并应用');
    final formatPosition = tester.getTopLeft(format);
    final validatePosition = tester.getTopLeft(validate);
    final savePosition = tester.getTopLeft(save);
    final editorBottom = tester.getBottomLeft(editor).dy;
    final title = find.text('高级配置');
    final toggle = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(SlidingSegmentedControl<AdvancedConfigMode>),
    );
    expect(tester.getCenter(toggle).dy, closeTo(tester.getCenter(title).dy, 1));
    expect(
      tester.getRect(toggle).left,
      greaterThan(tester.getRect(title).right),
    );
    expect(tester.getRect(toggle).right, closeTo(320 - 24, 1));
    final closeX = tester.getCenter(find.text('关闭')).dx;
    final extensionX = tester.getCenter(find.text('扩展')).dx;
    final overrideX = tester.getCenter(find.text('覆盖')).dx;
    expect(closeX, lessThan(extensionX));
    expect(extensionX, lessThan(overrideX));
    final fab = tester.getRect(find.byType(FloatingActionButton));
    expect(fab.right, closeTo(304, 1));
    expect(fab.bottom, closeTo(784, 1));
    expect(find.text('与生成的配置合并'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    await tester.enterText(editor, '{"log":{"level":"info"}}');
    await tester.tap(save);
    await tester.pump();
    expect(controller.snapshot.advancedJson, {
      'log': {'level': 'info'},
    });
    ScaffoldMessenger.of(tester.element(editor)).removeCurrentSnackBar();

    await tester.tap(find.text('覆盖'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(format).dy, formatPosition.dy);
    expect(tester.getTopLeft(validate).dy, validatePosition.dy);
    expect(tester.getTopLeft(save), savePosition);
    expect(tester.getBottomLeft(editor).dy, editorBottom);
    expect(find.text('使用完整的 sing-box 配置'), findsNothing);
    expect(find.text('载入完整配置'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(
      tester.getCenter(find.text('载入完整配置')).dy,
      closeTo(tester.getCenter(format).dy, 1),
    );
    expect(
      tester.getCenter(validate).dy,
      closeTo(tester.getCenter(format).dy, 1),
    );
    expect(
      controller.snapshot.advancedConfigMode,
      AdvancedConfigMode.extension,
    );

    await tester.binding.setSurfaceSize(const Size(360, 800));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.rule_rounded), findsOneWidget);
    final load = find.text('载入完整配置');
    final formatBounds = tester.getRect(format);
    for (final label in [validate, load]) {
      final bounds = tester.getRect(label);
      expect(bounds.height, closeTo(formatBounds.height, 0.01));
      expect(bounds.center.dy, closeTo(formatBounds.center.dy, 0.01));
    }

    await tester.enterText(editor, '{"outbounds":[]}');
    await tester.tap(save);
    await tester.pump();
    expect(controller.snapshot.customConfig, '{"outbounds":[]}');
    expect(controller.snapshot.useCustomConfig, isTrue);
    expect(controller.snapshot.advancedJson, isEmpty);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
    expect(controller.snapshot.advancedConfigMode, AdvancedConfigMode.override);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final saved = AppSnapshot.fromJson(controller.snapshot.toJson());
    expect(saved.advancedConfigMode, AdvancedConfigMode.off);
    expect(saved.advancedJson, isEmpty);
    expect(saved.customConfig, '{"outbounds":[]}');
    expect(saved.advancedJsonDraft, {
      'log': {'level': 'info'},
    });
    await tester.tap(find.text('扩展'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(editor).controller?.text,
      '{"log":{"level":"info"}}',
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      controller.snapshot.advancedConfigMode,
      AdvancedConfigMode.extension,
    );
    expect(controller.snapshot.advancedJson['log'], {'level': 'info'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('配置预览和剪贴板共用脱敏结果，真实配置不受影响', (tester) async {
    final controller = _ConfigController();
    addTearDown(controller.dispose);
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const AdvancedPage()),
      ),
    );
    final open = find.text('查看生成配置');
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    final preview = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data;
    expect(preview, contains('fixture-node'));
    expect(preview, contains('<已隐藏>'));
    for (final value in _secretValues) {
      expect(preview, isNot(contains(value)));
      expect(controller.config.encoded, contains(value));
    }
    await tester.tap(find.text('复制脱敏配置'));
    await tester.pump();
    expect(copied, preview);
  });

  testWidgets('覆写编辑器确认后载入完整配置，拒绝保存脱敏预览', (tester) async {
    final controller = _ConfigController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const ConfigPage()),
      ),
    );
    await tester.tap(find.text('覆盖'));
    await tester.pumpAndSettle();
    final editor = find.byType(TextField);
    final load = find.text('载入完整配置');
    final prior = tester.widget<TextField>(editor).controller?.text;

    await tester.tap(load);
    await tester.pumpAndSettle();
    expect(find.textContaining('编辑器将显示节点密码和私钥'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(editor).controller?.text, prior);

    await tester.tap(load);
    await tester.pumpAndSettle();
    await tester.tap(find.text('载入'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(editor).controller?.text,
      controller.config.encoded,
    );
    final save = find.text('保存并应用');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(controller.snapshot.customConfig, controller.config.encoded);
    ScaffoldMessenger.of(tester.element(editor))
      ..clearSnackBars()
      ..removeCurrentSnackBar();

    await tester.enterText(editor, jsonEncode(controller.config.redactedJson));
    await tester.tap(save);
    await tester.pump();
    expect(find.textContaining('脱敏占位符'), findsOneWidget);
    expect(controller.snapshot.customConfig, controller.config.encoded);
  });

  testWidgets('长 JSON 只在文本框内滚动，键盘弹出时文本框随页面缩小', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    tester.view.devicePixelRatio = 1;
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final controller = AppController();
    addTearDown(controller.dispose);
    final lines = List.generate(120, (index) => '  "field$index": $index');
    controller.snapshot.advancedJson = {
      for (var index = 0; index < lines.length; index++) 'field$index': index,
    };
    controller.snapshot.customConfig = '{\n${lines.join(',\n')}\n}';
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const ConfigPage()),
      ),
    );

    final editor = find.byType(TextField);
    final scrollable = find.descendant(
      of: editor,
      matching: find.byType(Scrollable),
    );
    final toolbar = find.text('格式化');
    final save = find.text('保存并应用');
    for (final tab in ['扩展', '覆盖']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      final bounds = tester.getRect(editor);
      final toolbarPosition = tester.getTopLeft(toolbar);
      final savePosition = tester.getTopLeft(save);
      expect(bounds.bottom, lessThan(savePosition.dy));
      expect(find.byType(Scrollable), findsOneWidget);
      final scroll = tester.state<ScrollableState>(scrollable).position;
      expect(scroll.maxScrollExtent, greaterThan(0));

      await tester.drag(editor, const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(scroll.pixels, greaterThan(0));
      expect(tester.getRect(editor), bounds);
      expect(tester.getTopLeft(toolbar), toolbarPosition);
      expect(tester.getTopLeft(save), savePosition);
    }

    final heightWithoutKeyboard = tester.getSize(editor).height;
    await tester.tap(editor);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    expect(tester.getSize(editor).height, lessThan(heightWithoutKeyboard));
    expect(tester.getSize(editor).height, greaterThan(0));
    expect(
      tester.getBottomLeft(editor).dy,
      lessThan(tester.getTopLeft(save).dy),
    );
    expect(tester.getBottomLeft(save).dy, lessThan(380));
    expect(tester.takeException(), isNull);
  });
}

const _secretValues = [
  'fixture-password',
  'fixture-user',
  'fixture-uuid',
  'fixture-auth',
  'fixture-key',
  'fixture-preshared',
  'fixture-bearer',
  'fixture-cookie',
  'fixture-url-login',
  'fixture-url-token',
];

class _ConfigController extends AppController {
  _ConfigController() {
    storage = _MemoryStorage();
    snapshot
      ..useCustomConfig = true
      ..customConfig = '{"outbounds":[]}';
  }

  late final config = CompiledConfig(
    json: _json,
    encoded: jsonEncode(_json),
    warnings: const [],
    nodeTags: const {},
    proxyGroupTag: 'proxy',
    autoGroupTag: 'auto',
    custom: true,
  );

  static const _json = <String, dynamic>{
    'inbounds': [
      {
        'users': [
          {'password': 'fixture-password', 'username': 'fixture-user'},
        ],
        'auth_password': 'fixture-auth',
      },
    ],
    'outbounds': [
      {
        'tag': 'fixture-node',
        'uuid': 'fixture-uuid',
        'headers': {
          'Authorization': 'fixture-bearer',
          'Cookie': ['fixture-cookie'],
        },
      },
    ],
    'endpoints': [
      {
        'private_key': 'fixture-key',
        'peers': [
          {'pre_shared_key': 'fixture-preshared'},
        ],
      },
    ],
    'route': {
      'rule_set': [
        {'url': 'https://fixture-url-login@example.invalid/rules'},
        {'url': 'https://example.invalid/rules?access=fixture-url-token'},
      ],
    },
  };

  @override
  Future<CompiledConfig> compileForExport() async => config;
}

class _MemoryStorage extends AppStorage {
  _MemoryStorage({this.fail = false}) : super(AppPaths.forDirectory('.'));

  final bool fail;

  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (fail) throw StateError('保存失败');
  }
}
