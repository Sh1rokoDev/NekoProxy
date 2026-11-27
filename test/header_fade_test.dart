import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/header_fade.dart';
import 'package:nekoproxy/app/widgets.dart';

void main() {
  testWidgets('页面内容从窗口顶部经过整块固定标题栏', (tester) async {
    const content = ValueKey('scrolling-content');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PageFrame(
            title: '首页',
            child: SizedBox(key: content, height: 1500),
          ),
        ),
      ),
    );

    final frost = find.byType(HeaderFrost);
    final title = find.text('首页');
    final frostBounds = tester.getRect(frost);
    final titleBounds = tester.getRect(title);
    final contentTop = tester.getTopLeft(find.byKey(content)).dy;
    expect(frostBounds.top, 0);
    expect(frostBounds.contains(titleBounds.center), isTrue);
    final pinnedHeader = tester.widget<PinnedHeaderSliver>(
      find.byType(PinnedHeaderSliver),
    );
    expect(
      contentTop,
      tester.getRect(find.byWidget(pinnedHeader.child!)).bottom,
    );
    expect(frostBounds.bottom, contentTop + 12);

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    scrollable.position.jumpTo(contentTop - titleBounds.center.dy);
    await tester.pump();

    expect(tester.getRect(frost), frostBounds);
    expect(tester.getRect(title), titleBounds);
    expect(tester.getTopLeft(find.byKey(content)).dy, titleBounds.center.dy);
  });

  testWidgets('主页面和详情页的标题、按钮及模糊层上下边界一致', (tester) async {
    const title = '页面标题';
    const action = HeaderIconButton(icon: Icons.refresh, tooltip: '刷新');
    addTearDown(tester.view.resetPadding);

    for (final (topInset, scale) in [(0.0, 1.0), (24.0, 1.0), (24.0, 2.0)]) {
      tester.view.padding = FakeViewPadding(
        top: topInset * tester.view.devicePixelRatio,
      );
      Widget withTextScale(BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      );

      final heading = find.text(title);
      final button = find.byTooltip('刷新');
      await tester.pumpWidget(
        MaterialApp(
          builder: withTextScale,
          home: const Scaffold(
            body: PageFrame(
              title: title,
              wrapHeader: true,
              actions: action,
              child: SizedBox(height: 200),
            ),
          ),
        ),
      );
      final titleBounds = tester.getRect(heading);
      final buttonBounds = tester.getRect(button);
      final frost = tester.getRect(find.byType(HeaderFrost));
      expect(frost.top, 0);
      if (scale == 1) {
        expect(buttonBounds.top, topInset + 23);
        expect(frost.bottom, topInset + 100);
      }

      await tester.pumpWidget(
        MaterialApp(
          builder: withTextScale,
          home: HeaderScaffold(
            title: const Text(title),
            actions: const [action],
            body: (_) => const SizedBox.expand(),
          ),
        ),
      );
      expect(tester.getRect(heading), titleBounds);
      expect(tester.getRect(button), buttonBounds);
      expect(tester.getRect(find.byType(HeaderFrost)), frost);
    }
  });

  testWidgets('详情页的模糊层从状态栏顶部开始，标题避开系统区域', (tester) async {
    const topInset = 24.0;
    tester.view.padding = FakeViewPadding(
      top: topInset * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.resetPadding);
    const firstRow = ValueKey('first-row');
    await tester.pumpWidget(
      MaterialApp(
        home: HeaderScaffold(
          title: const Text('详情'),
          body: (headerInset) => ListView(
            padding: EdgeInsets.only(top: headerInset),
            children: const [SizedBox(key: firstRow, height: 1500)],
          ),
        ),
      ),
    );

    final frostBounds = tester.getRect(find.byType(HeaderFrost));
    expect(frostBounds.top, 0);
    expect(frostBounds.bottom, topInset + 100);
    expect(tester.getTopLeft(find.text('详情')).dy, greaterThan(topInset));
    expect(tester.getTopLeft(find.byKey(firstRow)).dy, topInset + 88);

    tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(72);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(firstRow)).dy, topInset + 16);
    expect(tester.getRect(find.byType(HeaderFrost)), frostBounds);
  });

  testWidgets('详情页在窄屏将操作移到下一行，宽屏恢复到标题右侧', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var refreshed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => HeaderScaffold(
                    title: const Text('当前连接'),
                    actions: [
                      const HeaderIconButton(icon: Icons.search, tooltip: '搜索'),
                      HeaderIconButton(
                        icon: Icons.refresh,
                        tooltip: '刷新',
                        onPressed: () => refreshed = true,
                      ),
                      const HeaderIconButton(
                        icon: Icons.link_off,
                        tooltip: '关闭全部',
                      ),
                    ],
                    body: (inset) => Padding(
                      padding: EdgeInsets.only(top: inset),
                      child: const Text('连接列表'),
                    ),
                  ),
                ),
              ),
              child: const Text('打开详情'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    final title = find.text('当前连接');
    final refresh = find.byTooltip('刷新');
    final narrowTitleCenter = tester.getCenter(title).dy;
    expect(tester.getCenter(find.byTooltip('Back')).dy, narrowTitleCenter);
    expect(tester.getTopLeft(refresh).dy, 80);
    expect(
      tester.getTopLeft(find.text('连接列表')).dy,
      tester.getRect(refresh).bottom + 20,
    );
    await tester.tap(refresh);
    expect(refreshed, isTrue);

    await tester.binding.setSurfaceSize(const Size(1200, 700));
    await tester.pumpAndSettle();
    expect(tester.getCenter(title).dy, narrowTitleCenter);
    expect(
      tester.getCenter(refresh).dy,
      closeTo(tester.getCenter(title).dy, 1),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('打开详情'), findsOneWidget);
  });

  testWidgets('标题栏边缘的模糊逐渐减弱，底边下方恢复清晰', (tester) async {
    final preview = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(scaffoldBackgroundColor: Colors.white),
        home: Center(
          child: RepaintBoundary(
            key: preview,
            child: SizedBox(
              height: 60,
              width: 80,
              child: HeaderFade(
                extent: 30,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < 10; i++)
                      Expanded(
                        child: ColoredBox(
                          color: i.isEven ? Colors.black : Colors.white,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(preview),
    );
    final samples = await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        int red(int x, int y) => pixels!.getUint8((y * image.width + x) * 4);
        return (
          contrasts: [
            for (final y in [3, 15, 28, 30]) red(44, y) - red(36, y),
          ],
          whiteStripe: red(44, 15),
        );
      } finally {
        image.dispose();
      }
    });

    final [top, middle, edge, clear] = samples!.contrasts;
    // A white tint alone cannot darken a white stripe. Blur mixes it with
    // its black neighbors, so this checks for more than a color gradient.
    expect(samples.whiteStripe, lessThan(250));
    expect(top, lessThan(middle));
    expect(middle, lessThan(edge));
    expect(edge, closeTo(clear, 45));
    expect(clear, 255);
  });
}
