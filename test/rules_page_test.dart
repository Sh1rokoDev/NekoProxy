import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/widgets.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/rules/rules_page.dart';
import 'package:nekoproxy/runtime/runtime_client.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('包名匹配可搜索并批量选择应用，确认后填入规则草稿', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 820);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = _AndroidRulesController()..storage = _Storage();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const RulesPage()),
      ),
    );
    await tester.tap(find.text('应用过滤'));
    await tester.pumpAndSettle();
    expect(find.text('VPN 接管范围'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加规则'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '我的应用');
    await tester.tap(find.byType(DropdownButtonFormField<RuleKind>));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('包名').last);
    await tester.tap(find.text('包名').last);
    await tester.pumpAndSettle();

    final content = find.byType(TextField).at(1);
    await tester.enterText(content, 'app.manual');
    await tester.tap(find.byTooltip('选择应用'));
    await tester.pumpAndSettle();
    final picker = find.widgetWithText(AlertDialog, '选择应用');
    final search = find.descendant(
      of: picker,
      matching: find.widgetWithText(TextField, '搜索应用名或包名'),
    );
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 个'), findsOneWidget);
    await tester.enterText(search, '  APPROVAL  ');
    await tester.pumpAndSettle();
    expect(find.text('Approval'), findsOneWidget);
    expect(find.text('Camera'), findsNothing);
    await tester.tap(find.text('反选结果'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 个'), findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );

    await tester.enterText(search, 'APP.REVIEW');
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选结果'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 个'), findsOneWidget);
    await tester.tap(find.descendant(of: picker, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(content).controller?.text, 'app.manual');

    await tester.tap(find.byTooltip('选择应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(content).controller?.text,
      'app.manual\napp.camera',
    );
    expect(
      controller.snapshot.rules.any((rule) => rule.name == '我的应用'),
      isFalse,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final rule = controller.snapshot.rules.singleWhere(
      (rule) => rule.name == '我的应用',
    );
    expect(rule.kind, RuleKind.packageName);
    expect(splitRuleValues(rule.value), ['app.manual', 'app.camera']);
    expect(controller.settings.perAppMode, PerAppMode.off);
    expect(controller.settings.perAppPackages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('组合规则的应用选择只更新对应条件', (tester) async {
    final rule = RoutingRule(
      id: 'app-and-domain',
      name: '应用与域名',
      kind: RuleKind.packageName,
      value: 'app.camera',
      target: RuleTarget.proxy,
      logic: RuleLogic.and,
      conditions: [
        RuleCondition(kind: RuleKind.packageName, value: 'app.camera'),
        RuleCondition(kind: RuleKind.domainSuffix, value: 'example.com'),
      ],
    );
    final controller = _AndroidRulesController()
      ..storage = _Storage()
      ..snapshot.rules = [rule];
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const RulesPage()),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey(rule.id)),
        matching: find.byTooltip('编辑规则'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择应用'));
    await tester.pumpAndSettle();
    final camera = find.widgetWithText(CheckboxListTile, 'Camera');
    expect(tester.widget<CheckboxListTile>(camera).value, isTrue);
    await tester.tap(camera);
    await tester.tap(find.text('Approval'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
      controller.snapshot.rules.single.conditions.map((item) => item.value),
      ['app.review', 'example.com'],
    );
  });

  testWidgets('私网直连可编辑，核心规则和默认出站始终可见', (tester) async {
    final snapshot = AppSnapshot.empty();
    final enabled = snapshot.rules.first..enabled = true;
    final disabled = snapshot.rules[1]..enabled = false;
    snapshot.rules = [enabled, disabled];
    snapshot.settings.splitMode = SplitMode.rule;
    final controller = AppController()
      ..snapshot = snapshot
      ..storage = _Storage();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const RulesPage()),
      ),
    );

    final modes = find.byType(SlidingSegmentedControl<SplitMode>);
    final firstCard = find.byKey(ValueKey(enabled.id));
    final secondCard = find.byKey(ValueKey(disabled.id));
    final toggle = find.descendant(
      of: firstCard,
      matching: find.byType(Switch),
    );
    final inactiveLabel = find.textContaining('未生效');
    bool isEnabled(Finder row) => tester
        .widget<Switch>(find.descendant(of: row, matching: find.byType(Switch)))
        .value;
    TextDecoration? titleDecoration(Finder row, String title) => tester
        .widget<Text>(find.descendant(of: row, matching: find.text(title)))
        .style
        ?.decoration;

    Future<void> selectMode(String label) async {
      await tester.tap(find.descendant(of: modes, matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    expect(isEnabled(firstCard), isTrue);
    expect(isEnabled(secondCard), isFalse);
    expect(titleDecoration(firstCard, enabled.name), TextDecoration.none);
    expect(
      titleDecoration(secondCard, disabled.name),
      TextDecoration.lineThrough,
    );
    expect(inactiveLabel, findsNothing);
    expect(find.text('私网地址直连'), findsOneWidget);
    expect(find.text('识别流量协议'), findsOneWidget);
    expect(find.text('默认出站'), findsOneWidget);
    final editableTitleX = tester.getTopLeft(find.text('私网地址直连')).dx;
    expect(tester.getTopLeft(find.text('识别流量协议')).dx, editableTitleX);
    expect(tester.getTopLeft(find.text('默认出站')).dx, editableTitleX);
    for (final title in ['私网地址直连', '默认出站']) {
      final row = find.text(title);
      final feedback = tester.widget<InkWell>(
        find.ancestor(of: row, matching: find.byType(InkWell)),
      );
      expect(feedback.onTapDown, isNotNull);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    }
    expect(find.text('核心规则'), findsNothing);
    expect(find.text('可编辑规则'), findsNothing);
    expect(find.text('规则列表'), findsNothing);
    expect(find.text('动作'), findsNothing);
    expect(
      find.byType(Divider),
      findsNWidgets(
        controller.previewRouting().coreRules.length + snapshot.rules.length,
      ),
    );
    expect(
      tester.getTopLeft(find.text('识别流量协议')).dy,
      lessThan(tester.getTopLeft(firstCard).dy),
    );

    await selectMode('直连');
    expect(find.text('未命中规则时：直连'), findsOneWidget);
    expect(inactiveLabel, findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(enabled.enabled, isFalse);

    await selectMode('全局');
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(enabled.enabled, isTrue);
    expect(
      titleDecoration(firstCard, enabled.name),
      TextDecoration.lineThrough,
    );
    expect(inactiveLabel, findsNothing);
    expect(isEnabled(secondCard), isFalse);

    await tester.tap(
      find.descendant(of: firstCard, matching: find.byTooltip('编辑规则')),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, '编辑规则'), findsOneWidget);
    expect(find.text('匹配内容'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await selectMode('规则');
    expect(inactiveLabel, findsNothing);
    expect(isEnabled(secondCard), isFalse);
    expect(titleDecoration(firstCard, enabled.name), TextDecoration.none);

    final dragHandle = find.descendant(
      of: firstCard,
      matching: find.byTooltip('拖动调整顺序'),
    );
    final drag = await tester.startGesture(
      tester.getCenter(dragHandle),
      kind: PointerDeviceKind.mouse,
    );
    for (var step = 0; step < 12; step++) {
      await drag.moveBy(const Offset(0, 8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pumpAndSettle();
    expect(controller.snapshot.rules.map((rule) => rule.id), [
      disabled.id,
      enabled.id,
    ]);
  });

  testWidgets('窄屏显示胶囊动作和右下角悬浮添加按钮', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final snapshot = AppSnapshot.empty();
    final directRule = snapshot.rules.first;
    final quicRule = snapshot.rules.firstWhere(
      (rule) => rule.builtInId == 'quic-block',
    );
    final proxyRule = snapshot.rules.firstWhere(
      (rule) => rule.target == RuleTarget.proxy,
    );
    snapshot.rules = [directRule, proxyRule, quicRule];
    snapshot.settings.splitMode = SplitMode.rule;
    final controller = AppController()
      ..snapshot = snapshot
      ..storage = _Storage();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const RulesPage()),
      ),
    );

    Finder actionPill(Finder row, String label) => find.ancestor(
      of: find.descendant(of: row, matching: find.text(label)),
      matching: find.byWidgetPredicate(
        (widget) => switch (widget) {
          DecoratedBox(decoration: ShapeDecoration(shape: StadiumBorder())) =>
            true,
          _ => false,
        },
      ),
    );

    final firstRow = find.byKey(ValueKey(directRule.id));
    final edit = find.descendant(
      of: firstRow,
      matching: find.byTooltip('编辑规则'),
    );
    final pill = actionPill(firstRow, '直连');
    expect(pill, findsOneWidget);
    expect(
      tester.getTopRight(pill).dx,
      lessThanOrEqualTo(tester.getTopLeft(edit).dx),
    );
    final scheme = Theme.of(tester.element(pill)).colorScheme;
    final actions = [
      (directRule, '直连', scheme.tertiaryContainer, scheme.onTertiaryContainer),
      (proxyRule, '代理', scheme.primaryContainer, scheme.onPrimaryContainer),
      (quicRule, '阻断', scheme.errorContainer, scheme.onErrorContainer),
    ];
    final modes = find.byType(SlidingSegmentedControl<SplitMode>);
    for (final mode in ['直连', '全局', '规则']) {
      await tester.tap(find.descendant(of: modes, matching: find.text(mode)));
      await tester.pumpAndSettle();
      for (final (rule, label, background, foreground) in actions) {
        final action = actionPill(find.byKey(ValueKey(rule.id)), label);
        expect(
          tester.widget<DecoratedBox>(action).decoration,
          isA<ShapeDecoration>().having(
            (decoration) => decoration.color,
            'color',
            mode == '规则' ? background : scheme.surfaceContainerHighest,
          ),
        );
        final text = find.descendant(of: action, matching: find.text(label));
        expect(
          tester.widget<Text>(text).style?.color,
          mode == '规则' ? foreground : scheme.onSurfaceVariant,
        );
      }
    }
    final quicSummary = tester.widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey(quicRule.id)),
        matching: find.text('端口 443 · 网络 udp'),
      ),
    );
    expect(quicSummary.maxLines, 1);
    expect(quicSummary.overflow, TextOverflow.ellipsis);
    await tester.tap(find.text('识别流量协议'));
    await tester.pumpAndSettle();
    final details = find.descendant(
      of: find.widgetWithText(AlertDialog, '识别流量协议'),
      matching: find.byType(SelectableText),
    );
    expect(tester.widget<SelectableText>(details).data, contains('"sniff"'));
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    final add = find.widgetWithText(FloatingActionButton, '添加');
    expect(tester.getBottomRight(add), const Offset(336, 696));
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, '添加规则'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('JSON 接管时弹窗显示规则详情，列表保留默认出站', (tester) async {
    final controller = AppController()
      ..snapshot = (AppSnapshot.empty()
        ..useCustomConfig = true
        ..customConfig = '''
{
  "outbounds": [{"type": "direct", "tag": "wan"}],
  "route": {
    "rules": [
      {"domain": ["blocked.test"], "action": "reject"},
      {"domain": ["allowed.test"], "action": "route", "outbound": "wan"}
    ]
  }
}
''');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const RulesPage()),
      ),
    );
    expect(find.text('路由由 JSON 配置接管'), findsOneWidget);
    expect(find.textContaining('未生效'), findsNothing);
    expect(find.text('JSON 规则'), findsOneWidget);
    expect(find.text('识别流量协议'), findsNothing);
    expect(find.text('未命中规则时：wan'), findsOneWidget);
    final reject = find.byKey(const ValueKey('compiled-rule-0'));
    final route = find.byKey(const ValueKey('compiled-rule-1'));
    final routePosition = tester.getTopLeft(route);
    expect(tester.getTopLeft(reject).dy, lessThan(routePosition.dy));
    await tester.tap(find.descendant(of: reject, matching: find.text('阻断')));
    await tester.pumpAndSettle();
    final details = tester.widget<SelectableText>(
      find.descendant(
        of: find.widgetWithText(AlertDialog, '阻断'),
        matching: find.byType(SelectableText),
      ),
    );
    expect(details.data, contains('blocked.test'));
    expect(tester.getTopLeft(route), routePosition);
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
  });
}

class _Storage extends AppStorage {
  _Storage() : super(AppPaths.forDirectory(Directory.systemTemp.path));

  @override
  Future<void> save(AppSnapshot snapshot) async {}
}

class _AndroidRulesController extends AppController {
  @override
  bool get isAndroid => true;

  @override
  Future<List<InstalledApp>> installedApps() async => const [
    InstalledApp(packageName: 'app.camera', label: 'Camera'),
    InstalledApp(packageName: 'app.review', label: 'Approval'),
  ];

  @override
  Future<Uint8List?> installedAppIcon(String packageName, int size) async =>
      null;
}
