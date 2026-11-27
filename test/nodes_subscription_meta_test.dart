import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/dialogs.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/nodes/nodes_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('节点搜索替换标题、自动聚焦，关闭后恢复列表', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController()
      ..snapshot = AppSnapshot(
        settings: AppSettings(),
        subscriptions: [
          Subscription(
            id: 'group',
            name: '测试分组',
            nodes: [
              ProxyNode(
                id: 'node',
                tag: 'node',
                name: '東京',
                subscriptionId: 'group',
                outbound: {'type': 'http', 'server': 'tokyo.example.com'},
              ),
            ],
          ),
        ],
      );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

    await tester.tap(find.byTooltip('搜索节点'));
    await tester.pumpAndSettle();
    final search = find.byType(TextField);
    expect(find.text('节点'), findsNothing);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    await tester.enterText(search, '  TOKYO.EXAMPLE.COM ');
    await tester.pump();
    expect(find.text('東京'), findsOneWidget);
    await tester.enterText(search, '不存在的节点');
    await tester.pump();
    expect(find.text('没有匹配的节点'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();
    expect(search, findsNothing);
    expect(find.text('节点'), findsOneWidget);
    expect(find.text('東京'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('订阅卡片在缺少流量数据时显示暂无数据', (tester) async {
    final controller = AppController()
      ..snapshot = AppSnapshot(
        settings: AppSettings(),
        subscriptions: [
          Subscription(
            id: 'no-traffic',
            name: '无流量数据的订阅',
            url: 'https://example.com/no-traffic',
            lastUpdated: DateTime.now(),
          ),
          Subscription(
            id: 'no-metadata',
            name: '无元数据的订阅',
            url: 'https://example.com/no-metadata',
          ),
          Subscription(
            id: 'with-traffic',
            name: '有流量数据的订阅',
            url: 'https://example.com/with-traffic',
            totalBytes: 1024,
            downloadBytes: 512,
          ),
          Subscription(id: 'local-group', name: '本地分组'),
        ],
      );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

    final updated = find.text('刚刚更新');
    final fallback = find.text('暂无数据');
    expect(updated, findsOneWidget);
    expect(fallback, findsNWidgets(2));
    expect(tester.getTopLeft(fallback.first).dy, tester.getTopLeft(updated).dy);
    expect(find.text('50%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('本地分组'), findsOneWidget);
  });

  testWidgets('悬停和展开收起的按压反馈覆盖整张订阅卡片', (tester) async {
    final controller = AppController()
      ..snapshot = AppSnapshot(
        settings: AppSettings(),
        subscriptions: [
          Subscription(
            id: 'subscription',
            name: '测试订阅',
            url: 'https://example.com/subscription',
            nodes: [
              ProxyNode(
                id: 'test-node',
                tag: 'test-node',
                name: '测试节点',
                subscriptionId: 'subscription',
                outbound: const {'type': 'direct'},
              ),
            ],
          ),
        ],
      );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

    final title = find.text('测试订阅');
    final card = find
        .ancestor(of: title, matching: find.byType(AnimatedContainer))
        .first;
    Color? cardColor() =>
        (tester.widget<AnimatedContainer>(card).decoration as BoxDecoration)
            .color;

    final theme = Theme.of(tester.element(title));
    final normalColor = theme.colorScheme.surfaceContainerLow;
    final hoverColor = Color.alphaBlend(theme.hoverColor, normalColor);
    final expandIcon = find.byIcon(Icons.expand_more_rounded);
    final expandButton = find
        .ancestor(of: expandIcon, matching: find.byType(Container))
        .first;
    Color? expandColor() =>
        (tester.widget<Container>(expandButton).decoration as BoxDecoration)
            .color;

    final testButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.speed_rounded),
        matching: find.byType(IconButton),
      ),
    );
    final menuButton = tester.widget<PopupMenuButton<String>>(
      find.byWidgetPredicate(
        (widget) =>
            widget is PopupMenuButton<String> && widget.tooltip == '分组设置',
      ),
    );
    const hovered = {WidgetState.hovered};
    final buttonHoverColor = testButton.style?.overlayColor?.resolve(hovered);
    expect(buttonHoverColor, isNotNull);
    expect(buttonHoverColor, menuButton.style?.overlayColor?.resolve(hovered));

    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(find.text('测试节点'), findsNothing);
    final normalExpandColor = expandColor();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);

    expect(cardColor(), normalColor);
    await mouse.moveTo(tester.getCenter(title));
    await tester.pumpAndSettle();
    expect(cardColor(), hoverColor);
    expect(expandColor(), buttonHoverColor);
    expect(
      tester.widget<Icon>(expandIcon).color,
      theme.colorScheme.onSurfaceVariant,
    );

    await mouse.moveTo(tester.getCenter(find.text('暂无数据')));
    await tester.pumpAndSettle();
    expect(cardColor(), hoverColor);

    await mouse.moveTo(
      tester.getCenter(find.byIcon(Icons.drag_indicator_rounded)),
    );
    await tester.pumpAndSettle();
    expect(cardColor(), hoverColor);

    await tester.tap(title);
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.text('测试节点')));
    await tester.pumpAndSettle();
    expect(cardColor(), hoverColor);
    expect(expandColor(), buttonHoverColor);

    final pressOverlay = find.descendant(
      of: card,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is FadeTransition &&
            widget.child is ColoredBox &&
            (widget.child as ColoredBox).color == theme.highlightColor,
      ),
    );
    double pressOpacity() =>
        tester.widget<FadeTransition>(pressOverlay).opacity.value;

    final expandCenter = tester.getCenter(expandIcon);
    await mouse.moveTo(expandCenter);
    await mouse.down(expandCenter);
    await tester.pump(const Duration(milliseconds: 150));
    expect(pressOpacity(), 1);
    final cardBounds = tester.getRect(card);
    final border =
        (tester.widget<AnimatedContainer>(card).decoration as BoxDecoration)
            .border!;
    expect(
      tester.getRect(pressOverlay),
      border.dimensions.resolve(TextDirection.ltr).deflateRect(cardBounds),
    );
    await mouse.cancel();
    await tester.pumpAndSettle();
    expect(pressOpacity(), 0);
    expect(find.text('测试节点'), findsOneWidget);

    await tester.tap(expandIcon, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(find.text('测试节点'), findsNothing);
    expect(pressOpacity(), greaterThan(0));
    await tester.pumpAndSettle();
    expect(pressOpacity(), 0);

    await tester.tap(expandIcon);
    await tester.pump();
    expect(find.text('测试节点'), findsOneWidget);
    expect(pressOpacity(), greaterThan(0));
    await tester.pumpAndSettle();

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(cardColor(), normalColor);
    expect(expandColor(), normalExpandColor);
  });

  testWidgets('编辑订阅可独立设置自动更新开关和周期', (tester) async {
    final controller = AppController()
      ..storage = _MemoryStorage()
      ..snapshot = AppSnapshot(
        settings: AppSettings(),
        subscriptions: [
          Subscription(
            id: 'subscription',
            name: '测试订阅',
            url: 'https://example.com/subscription',
            autoUpdate: true,
            updateIntervalMinutes: 6 * 60,
          ),
        ],
      );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    Future<void> openEditor() async {
      await tester.tap(find.byTooltip('分组设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑订阅'));
      await tester.pumpAndSettle();
    }

    await openEditor();
    final intervalField = find.byType(TextFormField).last;
    expect(tester.widget<TextFormField>(intervalField).controller?.text, '6');
    await tester.enterText(intervalField, '12');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(controller.snapshot.subscriptions.single.autoUpdate, isTrue);
    expect(
      controller.snapshot.subscriptions.single.effectiveUpdateIntervalMinutes,
      12 * 60,
    );

    await openEditor();
    final autoUpdateSwitch = find.descendant(
      of: find.byType(AppDialog),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(autoUpdateSwitch).value, isTrue);
    await tester.tap(autoUpdateSwitch);
    await tester.pump();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField).last).enabled,
      isFalse,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(controller.snapshot.subscriptions.single.autoUpdate, isFalse);
    expect(
      controller.snapshot.subscriptions.single.effectiveUpdateIntervalMinutes,
      12 * 60,
    );
  });
}

class _MemoryStorage extends AppStorage {
  _MemoryStorage() : super(AppPaths.forDirectory(Directory.systemTemp.path));

  @override
  Future<void> save(AppSnapshot snapshot) async {}
}
