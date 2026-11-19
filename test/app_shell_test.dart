import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app.dart';
import 'package:nekoproxy/app/navigation_dock.dart';
import 'package:nekoproxy/app/sliding_segmented_control.dart';
import 'package:nekoproxy/features/home/home_page.dart';
import 'package:nekoproxy/features/nodes/nodes_page.dart';
import 'package:nekoproxy/features/rules/rules_page.dart';
import 'package:nekoproxy/features/tools/tools_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('底栏随按钮数量增宽，空间不足时均分可用宽度', (tester) async {
    const labels = ['首页', '节点', '规则', '更多', '设置'];

    Future<void> pumpDock(int count, double availableWidth) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: availableWidth),
              child: NavigationDock(
                axis: Axis.horizontal,
                destinations: [
                  for (var index = 0; index < count; index++)
                    SlidingSegmentOption(value: index, label: labels[index]),
                ],
                selected: 0,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    double buttonWidth(int index) =>
        tester.getCenter(_destination(labels[index + 1])).dx -
        tester.getCenter(_destination(labels[index])).dx;

    await pumpDock(4, 500);
    final fourButtonDock = tester.getSize(_navigation).width;
    final maxButtonWidth = buttonWidth(0);

    await pumpDock(3, 500);
    expect(tester.getSize(_navigation).width, fourButtonDock - maxButtonWidth);
    expect(buttonWidth(0), maxButtonWidth);

    await pumpDock(5, 500);
    expect(tester.getSize(_navigation).width, fourButtonDock + maxButtonWidth);
    expect(buttonWidth(3), maxButtonWidth);

    await pumpDock(5, 320);
    expect(tester.getSize(_navigation).width, 320);
    expect(buttonWidth(0), lessThan(maxButtonWidth));
    expect(buttonWidth(3), closeTo(buttonWidth(0), 0.01));
  });

  testWidgets('窄屏内容从底栏后方滚过，列表末项和添加规则入口不被遮挡', (tester) async {
    const size = Size(390, 680);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      NekoProxyApp(controller: controller),
      phase: EnginePhase.paint,
    );
    await _finishTransition(tester);

    await tester.tap(_destination('更多'));
    await _finishTransition(tester);
    final dock = tester.getRect(_navigation);
    final viewport = find.byType(Viewport);
    expect(dock.bottom, size.height - 34);
    expect(tester.getRect(viewport).bottom, size.height);

    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump(Duration.zero, EnginePhase.paint);
    final lastItem = find.widgetWithText(ListTile, '关于 NekoProxy');
    expect(tester.getRect(lastItem).bottom, lessThan(dock.top));
    expect(lastItem.hitTestable(), findsOneWidget);

    await tester.tap(_destination('规则'));
    await _finishTransition(tester);
    final addRule = find.widgetWithText(FloatingActionButton, '添加');
    expect(tester.getRect(addRule).bottom, lessThan(dock.top));
    expect(addRule.hitTestable(), findsOneWidget);

    final rulesScroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    rulesScroll.position.jumpTo(rulesScroll.position.maxScrollExtent);
    await tester.pump(Duration.zero, EnginePhase.paint);
    final fallback = find.widgetWithText(InkWell, '默认出站');
    expect(tester.getRect(fallback).bottom, lessThan(dock.top));
    expect(fallback.hitTestable(), findsOneWidget);
  });

  testWidgets('窗口缩放仅布局可见页面，切换标签保留首页滚动位置', (tester) async {
    tester.view.physicalSize = const Size(500, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      NekoProxyApp(controller: controller),
      phase: EnginePhase.paint,
    );
    await _finishTransition(tester);

    final home = find.byType(HomePage, skipOffstage: false);
    final nodes = find.byType(NodesPage, skipOffstage: false);
    final homeBox = tester.renderObject<RenderBox>(home);
    expect(homeBox.hasSize, isTrue);
    expect(nodes, findsNothing);
    expect(find.byType(RulesPage, skipOffstage: false), findsNothing);
    expect(find.byType(ToolsPage, skipOffstage: false), findsNothing);
    final homeConstraints = homeBox.constraints;
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: home, matching: find.byType(Scrollable)).first,
    );
    scrollable.position.jumpTo(80);
    await tester.pump(Duration.zero, EnginePhase.paint);

    await tester.tap(_destination('节点'));
    await _finishTransition(tester);
    tester.view.physicalSize = const Size(550, 600);
    await tester.pump(Duration.zero, EnginePhase.paint);

    final nodesBox = tester.renderObject<RenderBox>(nodes);
    expect(nodesBox.hasSize, isTrue);
    expect(nodesBox.constraints.maxWidth, 550);
    expect(homeBox.constraints, homeConstraints);

    await tester.tap(_destination('首页'));
    await _finishTransition(tester);
    expect(homeBox.constraints.maxWidth, 550);
    expect(scrollable.position.pixels, 80);

    for (var index = 0; index < 6; index++) {
      await tester.tap(_destination(index.isEven ? '节点' : '首页'));
      await tester.pump(const Duration(milliseconds: 20), EnginePhase.paint);
    }
    await _finishTransition(tester);
    final nodesConstraints = nodesBox.constraints;
    tester.view.physicalSize = const Size(520, 600);
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(homeBox.constraints.maxWidth, 520);
    expect(nodesBox.constraints, nodesConstraints);

    tester.view.physicalSize = const Size(1240, 900);
    await _finishTransition(tester);
    final desktopHomeBox = tester.renderObject<RenderBox>(home);
    final desktopNodesBox = tester.renderObject<RenderBox>(nodes);
    expect(desktopHomeBox, same(homeBox));
    expect(desktopNodesBox, same(nodesBox));
    final desktopHomeWidth = desktopHomeBox.constraints.maxWidth;
    expect(desktopNodesBox.constraints, nodesConstraints);
    tester.view.physicalSize = const Size(1280, 900);
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(desktopHomeBox.constraints.maxWidth, desktopHomeWidth + 40);
    expect(desktopNodesBox.constraints, nodesConstraints);

    tester.view.physicalSize = const Size(460, 380);
    await _finishTransition(tester);
    expect(homeBox.constraints.maxWidth, lessThan(460));
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(800, 900);
    await _finishTransition(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导航随窗口宽高比切换位置，拖动松开才换页', (tester) async {
    tester.view.physicalSize = const Size(360, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(NekoProxyApp(controller: controller));
    await _finishTransition(tester);

    int selected() => tester.widget<NavigationDock>(_navigation).selected;
    final narrow = tester.getRect(_navigation);
    expect(narrow.bottom, greaterThan(640));
    expect(narrow.left, greaterThan(0));
    expect(narrow.right, lessThan(360));
    final highlight = find.descendant(
      of: _navigation,
      matching: find.byKey(const ValueKey('segment-highlight')),
    );
    final first = tester.getRect(highlight);
    expect(first.left - narrow.left, closeTo(first.top - narrow.top, 0.1));
    expect(first.left - narrow.left, greaterThan(0));
    final home = tester.getCenter(_destination('首页'));
    final nodes = tester.getCenter(_destination('节点'));
    expect(home.dy, nodes.dy);
    final horizontal = await tester.startGesture(home);
    await horizontal.moveTo(nodes);
    await tester.pump();
    expect(selected(), 0);
    await horizontal.up();
    await _finishTransition(tester);
    expect(selected(), 1);

    tester.view.physicalSize = const Size(480, 420);
    await _finishTransition(tester);
    expect(tester.widget<NavigationDock>(_navigation).axis, Axis.vertical);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(680, 360);
    await _finishTransition(tester);
    expect(selected(), 1);
    expect(tester.widget<NavigationDock>(_navigation).axis, Axis.vertical);
    final wide = tester.getRect(_navigation);
    expect(wide.left, greaterThan(0));
    expect(wide.right, lessThan(110));
    expect(wide.center.dy, closeTo(180, 1));
    final start = tester.getCenter(_destination('节点'));
    final end = tester.getCenter(_destination('更多'));
    expect(start.dx, end.dx);
    expect(start.dy, lessThan(end.dy));
    final vertical = await tester.startGesture(start);
    await vertical.moveTo(end);
    await tester.pump();
    expect(selected(), 1);
    await vertical.up();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 16),
      EnginePhase.paint,
    );
    expect(selected(), 3);
    final last = tester.getRect(highlight);
    expect(wide.bottom - last.bottom, closeTo(last.left - wide.left, 0.1));

    tester.view.physicalSize = const Size(1024, 1024);
    await _finishTransition(tester);
    expect(selected(), 3);
    expect(tester.widget<NavigationDock>(_navigation).axis, Axis.horizontal);
    expect(tester.getRect(_navigation).bottom, greaterThan(980));

    tester.view.physicalSize = const Size(1024, 1100);
    await _finishTransition(tester);
    expect(tester.widget<NavigationDock>(_navigation).axis, Axis.horizontal);
    expect(tester.getRect(_navigation).bottom, greaterThan(1060));
  });

  testWidgets('按住时导航膨胀并预览目标，取消后选中块落回原位', (tester) async {
    tester.view.physicalSize = const Size(390, 750);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(NekoProxyApp(controller: controller));
    await tester.pumpAndSettle();

    final lens = find.descendant(
      of: _navigation,
      matching: find.byKey(const ValueKey('segment-highlight')),
    );
    final resting = tester.getRect(lens);
    final target = tester.getCenter(_destination('规则'));
    final pointer = await tester.startGesture(target);
    await tester.pumpAndSettle();

    expect(tester.widget<NavigationDock>(_navigation).selected, 0);
    expect(tester.getRect(lens).height, greaterThan(resting.height + 10));
    expect(tester.getCenter(lens).dx, closeTo(target.dx, 6));
    await pointer.cancel();
    await tester.pumpAndSettle();

    expect(tester.widget<NavigationDock>(_navigation).selected, 0);
    expect(tester.getCenter(lens).dx, closeTo(resting.center.dx, 1));
    expect(tester.getRect(lens).height, closeTo(resting.height, 1));
  });

  testWidgets('连续拖动时高亮持续跟随，快速松手可滑入相邻选项', (tester) async {
    tester.view.physicalSize = const Size(390, 750);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(NekoProxyApp(controller: controller));
    await tester.pumpAndSettle();

    final start = tester.getCenter(_destination('首页'));
    final nodes = tester.getCenter(_destination('节点'));
    final pitch = nodes.dx - start.dx;
    final pointer = await tester.startGesture(start);
    const frame = Duration(milliseconds: 16);
    for (var step = 1; step <= 10; step++) {
      await pointer.moveTo(
        start + Offset(pitch * 0.11 * step, 0),
        timeStamp: frame * step,
      );
      await tester.pump(frame);
    }

    final lens = find.descendant(
      of: _navigation,
      matching: find.byKey(const ValueKey('segment-highlight')),
    );
    expect(tester.getCenter(lens).dx, closeTo(nodes.dx, pitch * 0.36));
    expect(tester.widget<NavigationDock>(_navigation).selected, 0);
    await pointer.up(timeStamp: frame * 10);
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationDock>(_navigation).selected, 2);
  });
}

final _navigation = find.byType(NavigationDock);

Finder _destination(String label) =>
    find.descendant(of: _navigation, matching: find.text(label));

Future<void> _finishTransition(WidgetTester tester) async {
  await tester.pump(Duration.zero, EnginePhase.paint);
  await tester.pump(const Duration(milliseconds: 300), EnginePhase.paint);
  await tester.pump(Duration.zero, EnginePhase.paint);
}
