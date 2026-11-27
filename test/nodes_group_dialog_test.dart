import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/dialogs.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/nodes/nodes_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('创建和取消分组时弹窗均能正常退场', (tester) async {
    final controller = _GroupController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

    Future<void> openDialog() async {
      await tester.tap(find.widgetWithText(FloatingActionButton, '添加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('节点分组'));
      await tester.pumpAndSettle();
    }

    await openDialog();
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();
    expect(find.text('请输入分组名称'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), '  常用节点  ');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
    expect(find.text('常用节点'), findsOneWidget);

    await openDialog();
    await tester.enterText(find.byType(TextFormField), '不保存的分组');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
    expect(controller.snapshot.subscriptions.single.name, '常用节点');
  });
}

class _GroupController extends AppController {
  @override
  Future<Subscription> createGroup(String name) async {
    final group = Subscription(id: 'test-group', name: name);
    snapshot.subscriptions.add(group);
    notifyListeners();
    return group;
  }
}
