import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/features/tools/rule_sets_page.dart';
import 'package:nekoproxy/services/rule_set_manager.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  for (final width in [760.0, 1240.0]) {
    testWidgets('规则集详情在 $width 宽度下各占一行并右对齐', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = AppController()..ruleSetStatus = _RuleSetStatus();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(controller: controller, child: const RuleSetsPage()),
        ),
        phase: EnginePhase.paint,
      );

      final rightEdges = <double>[];
      for (final value in [
        '内置规则',
        '2026-11-11 09:37',
        '从未',
        '2021 个 · 1003.1 KB · 20261110034535',
        '253 个 · 4.0 MB · 202611080027',
      ]) {
        final editable = find.text(value);
        expect(editable, findsOneWidget);
        final render = tester.state<EditableTextState>(editable).renderEditable;
        final start = render.getLocalRectForCaret(
          const TextPosition(offset: 0),
        );
        final end = render.getLocalRectForCaret(
          TextPosition(offset: value.length),
        );
        expect(end.top, start.top);
        rightEdges.add(render.localToGlobal(end.topLeft).dx);
      }
      expect(rightEdges, everyElement(closeTo(rightEdges.first, 0.01)));
    });
  }
}

class _RuleSetStatus extends Fake implements RuleSetStatus {
  @override
  String get sourceLabel => '内置规则';

  @override
  DateTime get updatedAt => DateTime(2026, 11, 11, 9, 37);

  @override
  DateTime? get checkedAt => null;

  @override
  int count(String kind) => kind == 'geosite' ? 2021 : 253;

  @override
  int size(String kind) => kind == 'geosite' ? 1027174 : 4 * 1024 * 1024;

  @override
  String releaseTag(String kind) =>
      kind == 'geosite' ? '20261110034535' : '202611080027';
}
