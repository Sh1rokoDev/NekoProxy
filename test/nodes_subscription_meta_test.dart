import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/nodes/nodes_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
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
}
