import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/widgets.dart';
import 'package:nekoproxy/features/tools/rule_sets_page.dart';
import 'package:nekoproxy/services/rule_set_manager.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('更新和恢复按钮在规则集卡片下方右对齐并保留操作状态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _RuleSetActionsController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const RuleSetsPage()),
      ),
    );

    final card = find.byType(SectionCard);
    final update = find.widgetWithText(FilledButton, '检查更新');
    final reset = find.widgetWithText(OutlinedButton, '恢复内置');
    expect(card, findsOneWidget);
    expect(find.text('同步'), findsNothing);
    expect(
      tester.getRect(update).top,
      greaterThan(tester.getRect(card).bottom),
    );
    expect(
      tester.getCenter(update).dy,
      closeTo(tester.getCenter(reset).dy, 0.01),
    );
    expect(tester.getRect(update).right, lessThan(tester.getRect(reset).left));
    expect(
      tester.getRect(reset).right,
      closeTo(tester.getRect(card).right, 0.01),
    );

    await tester.tap(update);
    await tester.pump();
    expect(find.text('正在检查…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<OutlinedButton>(reset).onPressed, isNull);
    controller.update.complete();
    await tester.pumpAndSettle();
    expect(update, findsOneWidget);

    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(find.text('恢复内置规则'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.resets, 0);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    expect(controller.resets, 1);
  });

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

class _RuleSetActionsController extends AppController {
  final update = Completer<void>();
  int resets = 0;

  @override
  Future<void> updateRuleSets({bool automatic = false}) async {
    updatingRuleSets = true;
    notifyListeners();
    await update.future;
    updatingRuleSets = false;
    notifyListeners();
  }

  @override
  Future<void> resetBuiltInRuleSets() async => resets++;
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
