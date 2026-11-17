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
  testWidgets('私网直连可编辑，核心规则和默认出站始终可见', (tester) async {
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
    expect(find.text('私网地址直连'), findsOneWidget);
    expect(find.text('识别流量协议'), findsOneWidget);
    expect(find.text('默认出站'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('识别流量协议')).dy,
      lessThan(tester.getTopLeft(firstCard).dy),
    );

    await selectMode('直连');
    expect(find.text('未命中规则时：直连'), findsOneWidget);
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
    expect(find.text('匹配内容'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await selectMode('规则');
    expect(opacity(firstCard), 1);
    expect(opacity(secondCard), 0.5);
  });

  testWidgets('JSON 接管时列出实际规则和默认出站', (tester) async {
    final controller = AppController()
      ..snapshot = (AppSnapshot.empty()
        ..useCustomConfig = true
        ..customConfig = '''
{
  "outbounds": [{"type": "direct", "tag": "wan"}],
  "route": {
    "rules": [
      {"domain": ["blocked.test"], "action": "reject"},
      {"domain": ["allowed.test"], "action": "route", "outbound": "wan"}
    ]
  }
}
''');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const RulesPage()),
      ),
    );
    expect(find.text('路由由 JSON 配置接管'), findsOneWidget);
    expect(find.text('识别流量协议'), findsNothing);
    expect(find.text('未命中规则时：wan'), findsOneWidget);
    final reject = find.byKey(const ValueKey('compiled-rule-0'));
    final route = find.byKey(const ValueKey('compiled-rule-1'));
    expect(tester.getTopLeft(reject).dy, lessThan(tester.getTopLeft(route).dy));
    await tester.tap(find.descendant(of: reject, matching: find.text('阻断')));
    await tester.pumpAndSettle();
    final details = tester.widget<SelectableText>(
      find.descendant(of: reject, matching: find.byType(SelectableText)),
    );
    expect(details.data, contains('blocked.test'));
  });
}

class _Storage extends AppStorage {
  _Storage() : super(AppPaths.forDirectory(Directory.systemTemp.path));

  @override
  Future<void> save(AppSnapshot snapshot) async {}
}
