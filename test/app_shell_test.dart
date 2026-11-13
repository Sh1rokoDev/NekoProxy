import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app.dart';
import 'package:nekoproxy/features/home/home_page.dart';
import 'package:nekoproxy/features/nodes/nodes_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('窗口缩放仅布局可见页面，切换标签保留首页滚动位置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
    final nodesBox = tester.renderObject<RenderBox>(nodes);
    expect(homeBox.hasSize, isTrue);
    expect(nodesBox.hasSize, isFalse);
    final homeConstraints = homeBox.constraints;
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: home, matching: find.byType(Scrollable)).first,
    );
    scrollable.position.jumpTo(80);
    await tester.pump(Duration.zero, EnginePhase.paint);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('节点'),
      ),
    );
    await _finishTransition(tester);
    await tester.binding.setSurfaceSize(const Size(850, 900));
    await tester.pump(Duration.zero, EnginePhase.paint);

    expect(nodesBox.hasSize, isTrue);
    expect(nodesBox.constraints.maxWidth, 850);
    expect(homeBox.constraints, homeConstraints);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('首页'),
      ),
    );
    await _finishTransition(tester);
    expect(homeBox.constraints.maxWidth, 850);
    expect(scrollable.position.pixels, 80);

    for (var index = 0; index < 6; index++) {
      tester
          .widget<NavigationBar>(find.byType(NavigationBar))
          .onDestinationSelected!((index + 1) % 2);
      await tester.pump(const Duration(milliseconds: 20), EnginePhase.paint);
    }
    await _finishTransition(tester);
    final nodesConstraints = nodesBox.constraints;
    await tester.binding.setSurfaceSize(const Size(820, 900));
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(homeBox.constraints.maxWidth, 820);
    expect(nodesBox.constraints, nodesConstraints);

    await tester.binding.setSurfaceSize(const Size(1240, 900));
    await _finishTransition(tester);
    final desktopHomeBox = tester.renderObject<RenderBox>(home);
    final desktopNodesBox = tester.renderObject<RenderBox>(nodes);
    final desktopHomeWidth = desktopHomeBox.constraints.maxWidth;
    expect(desktopNodesBox.hasSize, isFalse);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pump(Duration.zero, EnginePhase.paint);
    expect(desktopHomeBox.constraints.maxWidth, desktopHomeWidth + 40);
    expect(desktopNodesBox.hasSize, isFalse);

    await tester.binding.setSurfaceSize(const Size(800, 900));
    await _finishTransition(tester);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _finishTransition(WidgetTester tester) async {
  await tester.pump(Duration.zero, EnginePhase.paint);
  await tester.pump(const Duration(milliseconds: 300), EnginePhase.paint);
  await tester.pump(Duration.zero, EnginePhase.paint);
}
