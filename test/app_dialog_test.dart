import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nekoproxy/app/dialogs.dart';

void main() {
  testWidgets('窄屏弹窗滚动正文时保留标题与保存按钮', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 380);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    var saved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved =
                    await showAppDialog<bool>(
                      context: context,
                      builder: (context) => AppDialog(
                        size: AppDialogSize.wide,
                        title: const Text('编辑规则'),
                        content: Column(
                          children: [
                            for (var index = 1; index <= 20; index++)
                              SizedBox(height: 44, child: Text('条件 $index')),
                          ],
                        ),
                        actions: [
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('保存'),
                          ),
                        ],
                      ),
                    ) ??
                    false;
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final scrollView = find.byType(SingleChildScrollView);
    final title = find.text('编辑规则');
    final save = find.widgetWithText(FilledButton, '保存');
    final titleOrigin = tester.getTopLeft(title);
    final saveOrigin = tester.getTopLeft(save);
    final lastCondition = find.text('条件 20');
    expect(lastCondition.hitTestable(), findsNothing);

    await tester.scrollUntilVisible(lastCondition, 160);
    expect(lastCondition.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(title), titleOrigin);
    expect(tester.getTopLeft(save), saveOrigin);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(scrollView, findsNothing);
    expect(saved, isTrue);
  });
}
