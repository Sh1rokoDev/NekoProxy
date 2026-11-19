import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'sliding_segmented_control.dart';

/// An opaque dock with a lifted selection that follows the pointer.
class NavigationDock extends StatelessWidget {
  const NavigationDock({
    super.key,
    required this.destinations,
    required this.selected,
    required this.onSelected,
    required this.axis,
  });

  static const _maxButtonWidth = 72.0;
  static const _maxButtonHeight = 58.0;

  final List<SlidingSegmentOption<int>> destinations;
  final int selected;
  final ValueChanged<int> onSelected;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final vertical = axis == Axis.vertical;
    final textGrowth = math.max(
      0.0,
      MediaQuery.textScalerOf(context).scale(11) - 11,
    );
    return SlidingSegmentedControl<int>(
      width: 64 + textGrowth,
      height: 60 + textGrowth,
      maxSegmentExtent: vertical
          ? _maxButtonHeight + textGrowth
          : _maxButtonWidth,
      segments: destinations,
      selected: selected,
      onChanged: onSelected,
      axis: axis,
      navigation: true,
    );
  }
}
