import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/widgets.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/rules/rules_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('直连和全局模式淡化所有规则，开关和编辑仍可使用', (tester) async {
    final snapshot = AppSnapshot.empty();
    final enabled = snapshot.rules.first..enabled = true;
    final disabled = snapshot.rules[1]..enabled = false;
    snapshot.rules = [enabled, disabled];
    snapshot.settings.splitMode = SplitMode.rule;
    final controller = AppController()
      ..snapshot = snapshot
      ..storage = _Storage();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const RulesPage()),
      ),
    );

    final modes = find.byType(SlidingSegmentedControl<SplitMode>);
    final firstCard = find.byKey(ValueKey(enabled.id));
    final secondCard = find.byKey(ValueKey(disabled.id));
    final toggle = find.descendant(
      of: firstCard,
      matching: find.byType(Switch),
    );
    double opacity(Finder card) => tester
        .widget<AnimatedOpacity>(
          find.descendant(of: card, matching: find.byType(AnimatedOpacity)),
        )
        .opacity;

    Future<void> selectMode(String label) async {
      await tester.tap(find.descendant(of: modes, matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    expect(opacity(firstCard), 1);
    expect(opacity(secondCard), 0.5);

    await selectMode('直连');
    expect(opacity(firstCard), 0.5);
    expect(opacity(secondCard), 0.5);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(enabled.enabled, isFalse);

    await selectMode('全局');
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(enabled.enabled, isTrue);
    expect(opacity(firstCard), 0.5);
    expect(opacity(secondCard), 0.5);

    await tester.tap(
      find.descendant(of: firstCard, matching: find.byTooltip('编辑规则')),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, '编辑规则'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await selectMode('规则');
    expect(opacity(firstCard), 1);
    expect(opacity(secondCard), 0.5);
  });
}

class _Storage extends AppStorage {
  _Storage() : super(AppPaths.forDirectory(Directory.systemTemp.path));

  @override
  Future<void> save(AppSnapshot snapshot) async {}
}
