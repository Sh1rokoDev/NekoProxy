import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/widgets.dart';

const _highlightColor = Colors.teal;

Future<void> _mount(
  WidgetTester tester,
  ValueChanged<int>? onChanged, {
  bool reduceMotion = false,
  TextDirection direction = TextDirection.ltr,
}) async {
  var selected = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: const ColorScheme.light(
          secondaryContainer: _highlightColor,
        ),
      ),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) => SlidingSegmentedControl<int>(
                  width: 240,
                  segments: const [
                    SlidingSegmentOption(value: 0, label: '直连'),
                    SlidingSegmentOption(value: 1, label: '规则'),
                    SlidingSegmentOption(value: 2, label: '全局'),
                  ],
                  selected: selected,
                  onChanged: onChanged == null
                      ? null
                      : (value) {
                          onChanged(value);
                          setState(() => selected = value);
                        },
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

final _highlight = find.byWidgetPredicate(
  (widget) =>
      widget is DecoratedBox &&
      widget.decoration is BoxDecoration &&
      (widget.decoration as BoxDecoration).color == _highlightColor,
);

final _track = find.ancestor(
  of: _highlight,
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is DecoratedBox &&
        widget.decoration is BoxDecoration &&
        (widget.decoration as BoxDecoration).border != null,
  ),
);

void main() {
  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('$kind 拖动时高亮跟随，松开后仅提交最终选项', (tester) async {
      final changes = <int>[];
      await _mount(tester, changes.add);

      final start = tester.getCenter(find.text('直连'));
      final middle = tester.getCenter(find.text('规则'));
      final end = tester.getCenter(find.text('全局'));
      final pointer = await tester.startGesture(start, kind: kind);
      final between = Offset.lerp(start, middle, 0.7)!;
      await pointer.moveTo(between);
      await tester.pumpAndSettle();

      expect(tester.getCenter(_highlight).dx, closeTo(between.dx, 2));
      _expectHighlightPastTrack(tester);
      expect(changes, isEmpty);

      await pointer.moveTo(end + const Offset(40, 0));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(changes, [2]);
      expect(tester.getCenter(_highlight).dx, closeTo(end.dx, 1));
    });
  }

  testWidgets('点击有短促反馈，按住保持放大，松开复位', (tester) async {
    final changes = <int>[];
    await _mount(tester, changes.add);
    double highlightHeight() => tester.getRect(_highlight).height;
    final restingHeight = highlightHeight();

    await tester.tap(find.text('直连'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(highlightHeight(), greaterThan(restingHeight));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(highlightHeight(), closeTo(restingHeight, 0.1));

    final pointer = await tester.startGesture(
      tester.getCenter(find.text('规则')),
    );
    await tester.pumpAndSettle();
    _expectHighlightPastTrack(tester);
    expect(
      tester.getCenter(_highlight).dx,
      closeTo(tester.getCenter(find.text('规则')).dx, 2),
    );
    expect(changes, isEmpty);
    await pointer.up();
    await tester.pumpAndSettle();
    expect(changes, [1]);
    expect(highlightHeight(), closeTo(restingHeight, 0.1));
  });

  testWidgets('从分段按钮上纵向滑动不会误切换', (tester) async {
    final changes = <int>[];
    await _mount(tester, changes.add);
    final original = tester.getCenter(_highlight);
    final pointer = await tester.startGesture(
      tester.getCenter(find.text('规则')),
    );
    await pointer.moveBy(const Offset(0, 70));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect((tester.getCenter(_highlight) - original).distance, lessThan(0.1));
  });

  testWidgets('反向布局中的拖动取消后复位，键盘仍可切换', (tester) async {
    final changes = <int>[];
    await _mount(tester, changes.add, direction: TextDirection.rtl);
    final start = tester.getCenter(find.text('直连'));
    final end = tester.getCenter(find.text('全局'));
    expect(start.dx, greaterThan(end.dx));
    final pointer = await tester.startGesture(start);
    await pointer.moveTo(end);
    await tester.pumpAndSettle();
    expect(tester.getCenter(_highlight).dx, closeTo(end.dx, 4));
    await pointer.cancel();
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(tester.getCenter(_highlight).dx, closeTo(start.dx, 1));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(changes, [1]);
  });

  testWidgets('减少动态效果时不缩放，禁用时不响应点击和拖动', (tester) async {
    final changes = <int>[];
    await _mount(tester, changes.add, reduceMotion: true);
    final restingHeight = tester.getRect(_highlight).height;
    final end = tester.getCenter(find.text('全局'));
    final pointer = await tester.startGesture(end);
    await tester.pumpAndSettle();
    expect(tester.getRect(_highlight).height, restingHeight);
    await pointer.up();
    await tester.pump();
    expect(changes, [2]);
    expect(tester.getCenter(_highlight).dx, closeTo(end.dx, 1));

    await _mount(tester, null);
    await tester.tap(find.text('规则'));
    await tester.dragFrom(
      tester.getCenter(find.text('直连')),
      const Offset(155, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(_highlight).dx,
      closeTo(tester.getCenter(find.text('直连')).dx, 1),
    );
  });
}

void _expectHighlightPastTrack(WidgetTester tester) {
  final highlight = tester.getRect(_highlight);
  final track = tester.getRect(_track);
  expect(track.top - highlight.top, greaterThan(1));
  expect(highlight.bottom - track.bottom, greaterThan(1));
}
