import 'package:flutter/material.dart';

import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';

class SplitModeSwitch extends StatelessWidget {
  const SplitModeSwitch({
    super.key,
    required this.controller,
    this.width = 168,
  });

  final AppController controller;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SlidingSegmentedControl<SplitMode>(
      width: width,
      segments: const [
        SlidingSegmentOption(value: SplitMode.direct, label: '直连'),
        SlidingSegmentOption(value: SplitMode.rule, label: '规则'),
        SlidingSegmentOption(value: SplitMode.global, label: '全局'),
      ],
      selected: controller.settings.splitMode,
      onChanged: controller.canChangeSplitMode ? controller.setSplitMode : null,
    );
  }
}
