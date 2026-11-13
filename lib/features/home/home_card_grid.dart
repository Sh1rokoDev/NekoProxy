import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Lays out equal-width cards in order, placing each in the shortest column.
class HomeCardGrid extends MultiChildRenderObjectWidget {
  const HomeCardGrid({
    super.key,
    required this.columns,
    required this.spacing,
    this.animationVsync,
    required super.children,
  });

  final int columns;
  final double spacing;
  final TickerProvider? animationVsync;

  static ({int index, Rect bounds})? slotAt(
    BuildContext? context,
    Offset position,
  ) {
    final grid = context?.findRenderObject();
    return grid is _RenderHomeCardGrid ? grid.slotAt(position) : null;
  }

  @override
  RenderBox createRenderObject(BuildContext context) => _RenderHomeCardGrid(
    columns,
    spacing,
    Directionality.of(context),
    animationVsync,
  );

  @override
  void updateRenderObject(BuildContext context, RenderBox renderObject) {
    (renderObject as _RenderHomeCardGrid).updateLayout(
      columns,
      spacing,
      Directionality.of(context),
      animationVsync,
    );
  }
}

class _CardParentData extends ContainerBoxParentData<RenderBox> {
  Offset? target;
  Offset start = Offset.zero;
}

class _RenderHomeCardGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _CardParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _CardParentData> {
  _RenderHomeCardGrid(
    this._columns,
    this._spacing,
    this._direction,
    TickerProvider? vsync,
  ) {
    _setVsync(vsync);
  }

  int _columns;
  double _spacing;
  TextDirection _direction;
  TickerProvider? _vsync;
  AnimationController? _movement;

  void updateLayout(
    int columns,
    double spacing,
    TextDirection direction,
    TickerProvider? vsync,
  ) {
    _setVsync(vsync);
    if (_columns == columns && _spacing == spacing && _direction == direction) {
      return;
    }
    _columns = columns;
    _spacing = spacing;
    _direction = direction;
    markNeedsLayout();
  }

  void _setVsync(TickerProvider? vsync) {
    if (_vsync == vsync) return;
    _movement?.dispose();
    _vsync = vsync;
    _movement = vsync == null
        ? null
        : (AnimationController(
            vsync: vsync,
            duration: const Duration(milliseconds: 200),
          )..addListener(_updatePositions));
    if (vsync == null) _updatePositions();
  }

  void _updatePositions() {
    final progress = Curves.easeOutCubic.transform(_movement?.value ?? 1);
    RenderBox? child = firstChild;
    while (child != null) {
      final data = child.parentData as _CardParentData;
      if (data.target case final target?) {
        data.offset = Offset.lerp(data.start, target, progress)!;
      }
      child = data.nextSibling;
    }
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  // Use destination slots for reordering so cards sliding past the pointer
  // don't cause another move before they reach their new positions.
  ({int index, Rect bounds})? slotAt(Offset globalPosition) {
    if (!hasSize || !attached) return null;
    final local = globalToLocal(globalPosition);
    var index = 0;
    for (RenderBox? child = firstChild; child != null; index++) {
      final data = child.parentData as _CardParentData;
      if (data.target case final target? when child.hasSize) {
        final bounds = target & child.size;
        if (bounds.contains(local)) {
          return (index: index, bounds: localToGlobal(target) & child.size);
        }
      }
      child = data.nextSibling;
    }
    return null;
  }

  @override
  void dispose() {
    _movement?.dispose();
    super.dispose();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CardParentData) {
      child.parentData = _CardParentData();
    }
  }

  Size _layoutCards(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.maxWidth;
    final cardWidth = (width - _spacing * (_columns - 1)) / _columns;
    final cardConstraints = BoxConstraints.tightFor(width: cardWidth);
    final columnBottoms = List.filled(_columns, -_spacing);
    var moved = false;
    var child = firstChild;
    while (child != null) {
      final parentData = child.parentData as _CardParentData;
      var column = 0;
      for (var index = 1; index < _columns; index++) {
        if (columnBottoms[index] < columnBottoms[column]) column = index;
      }
      final top = columnBottoms[column] + _spacing;
      final double height;
      if (dry) {
        height = child.getDryLayout(cardConstraints).height;
      } else {
        child.layout(cardConstraints, parentUsesSize: true);
        height = child.size.height;
        final visualColumn = _direction == TextDirection.ltr
            ? column
            : _columns - 1 - column;
        final target = Offset(visualColumn * (cardWidth + _spacing), top);
        final previous = parentData.target;
        if (_movement == null || previous == null) {
          parentData.start = parentData.offset = target;
        } else if (previous != target) {
          moved = true;
        }
        parentData.target = target;
      }
      columnBottoms[column] = top + height;
      child = parentData.nextSibling;
    }
    if (moved) {
      for (RenderBox? child = firstChild; child != null;) {
        final data = child.parentData as _CardParentData;
        data.start = data.offset;
        child = data.nextSibling;
      }
      _movement?.forward(from: 0);
    }
    return constraints.constrain(
      Size(width, columnBottoms.fold(0.0, math.max)),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layoutCards(constraints, dry: true);

  @override
  void performLayout() => size = _layoutCards(constraints, dry: false);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
