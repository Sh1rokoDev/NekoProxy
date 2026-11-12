import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/widgets.dart';
import 'package:nekoproxy/features/tools/about_page.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('关于页显示应用图标并并排显示开源协议和许可证入口', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'NekoProxy',
      packageName: 'nekoproxy',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: AboutPage()),
      phase: EnginePhase.paint,
    );
    expect(
      find.image(const AssetImage('assets/icons/app_icon.png')),
      findsOneWidget,
    );
    expect(find.text('隐私'), findsNothing);
    expect(find.text('开源与致谢'), findsNothing);
    expect(find.text('许可证'), findsNothing);
    expect(find.text('本地端口'), findsNothing);

    double rightEdgeOf(String value) {
      final render = tester
          .state<EditableTextState>(find.text(value))
          .renderEditable;
      final end = render.getLocalRectForCaret(
        TextPosition(offset: value.length),
      );
      return render.localToGlobal(end.topLeft).dx;
    }

    expect(
      rightEdgeOf('sing-box 1.14.4'),
      closeTo(rightEdgeOf('Flutter · Material 3'), 0.01),
    );

    final section = find.widgetWithText(SectionCard, '开源协议');
    final license = find.descendant(
      of: section,
      matching: find.text('GPL-3.0-or-later'),
    );
    final button = find.descendant(of: section, matching: find.text('查看开源许可证'));
    expect(
      tester.getCenter(button).dx,
      greaterThan(tester.getCenter(license).dx),
    );
    expect(
      tester.getCenter(button).dy,
      closeTo(tester.getCenter(license).dy, 1),
    );

    await tester.tap(button);
    await tester.pump(Duration.zero, EnginePhase.paint);
    await tester.pump(const Duration(milliseconds: 350), EnginePhase.paint);
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
