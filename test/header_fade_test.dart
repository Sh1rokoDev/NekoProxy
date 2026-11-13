import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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
    expect(frostBounds.bottom, contentTop);

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    scrollable.position.jumpTo(contentTop - titleBounds.center.dy);
    await tester.pump();

    expect(tester.getRect(frost), frostBounds);
    expect(tester.getRect(title), titleBounds);
    expect(tester.getTopLeft(find.byKey(content)).dy, titleBounds.center.dy);
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
            padding: EdgeInsets.only(top: headerInset + 20),
            children: const [SizedBox(key: firstRow, height: 1500)],
          ),
        ),
      ),
    );

    final frostBounds = tester.getRect(find.byType(HeaderFrost));
    expect(frostBounds.top, 0);
    expect(frostBounds.bottom, topInset + kToolbarHeight + 20);
    expect(tester.getTopLeft(find.text('详情')).dy, greaterThan(topInset));
    expect(tester.getTopLeft(find.byKey(firstRow)).dy, frostBounds.bottom);

    tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(72);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(firstRow)).dy, frostBounds.bottom - 72);
    expect(tester.getRect(find.byType(HeaderFrost)), frostBounds);
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
