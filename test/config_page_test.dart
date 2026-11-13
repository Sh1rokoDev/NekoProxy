import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/features/tools/config_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('两个 JSON 模式共用编辑布局并分别保存草稿', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _ConfigController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: AppScope(controller: controller, child: const ConfigPage()),
      ),
    );

    final editor = find.byType(TextField);
    final format = find.text('格式化');
    final validate = find.text('校验');
    final save = find.text('保存并应用');
    final formatPosition = tester.getTopLeft(format);
    final validatePosition = tester.getTopLeft(validate);
    final savePosition = tester.getTopLeft(save);
    final editorHeight = tester.getSize(editor).height;
    expect(find.text('与生成的配置合并'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    await tester.enterText(editor, '{"log":{"level":"info"}}');
    await tester.tap(save);
    await tester.pump();
    expect(controller.snapshot.advancedJson, {
      'log': {'level': 'info'},
    });
    ScaffoldMessenger.of(tester.element(editor)).removeCurrentSnackBar();

    await tester.tap(find.text('自定义配置'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(format), formatPosition);
    expect(tester.getTopLeft(validate), validatePosition);
    expect(tester.getTopLeft(save), savePosition);
    expect(tester.getSize(editor).height, editorHeight);
    expect(find.text('使用完整的 sing-box 配置'), findsNothing);
    expect(find.text('载入当前生成配置'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);

    await tester.enterText(editor, '{"outbounds":[]}');
    await tester.tap(save);
    await tester.pump();
    expect(controller.snapshot.customConfig, '{"outbounds":[]}');
    expect(controller.snapshot.useCustomConfig, isFalse);
    await tester.tap(find.text('JSON 扩展'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(editor).controller?.text,
      '{"log":{"level":"info"}}',
    );
    expect(tester.takeException(), isNull);
  });
}

class _ConfigController extends AppController {
  @override
  Future<void> saveAdvancedJson(Map<String, dynamic> json) async {
    snapshot.advancedJson = json;
  }

  @override
  Future<void> setCustomConfig(String config, bool useCustom) async {
    snapshot.customConfig = config;
    snapshot.useCustomConfig = useCustom;
  }
}
