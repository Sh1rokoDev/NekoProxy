import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nekoproxy/app/app.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  final binding = _RecordingBinding();

  testWidgets('主题弹窗打开时只提交无障碍树中的节点', (tester) async {
    final handle = tester.ensureSemantics();
    final controller = AppController();
    addTearDown(controller.dispose);
    try {
      await tester.pumpWidget(NekoProxyApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      expect(binding.unreachableNodes, isEmpty);

      await tester.tap(find.widgetWithText(TextButton, '主题'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(binding.unreachableNodes, isEmpty);

      expect(
        tester.getSemantics(find.byType(Slider)).getSemanticsData().label,
        '界面缩放',
      );
      final slider = find.semantics
          .byAction(ui.SemanticsAction.increase)
          .evaluate()
          .single
          .getSemanticsData();
      expect(slider.value, '100%');
      expect(slider.hasAction(ui.SemanticsAction.decrease), isTrue);
    } finally {
      handle.dispose();
    }
  });
}

class _RecordingBinding extends AutomatedTestWidgetsFlutterBinding {
  final tree = <int, List<int>>{};
  final unreachableNodes = <int>[];

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() => _Recorder(this);
}

class _Recorder implements ui.SemanticsUpdateBuilder {
  _Recorder(this.binding);

  final _RecordingBinding binding;
  final _delegate = ui.SemanticsUpdateBuilder();
  final _children = <int, List<int>>{};

  @override
  Object? noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final args = invocation.namedArguments;
      final id = args[#id] as int;
      _children[id] = args[#childrenInTraversalOrder] as List<int>;
      return Function.apply(_delegate.updateNode, [], args);
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(
        _delegate.updateCustomAction,
        [],
        invocation.namedArguments,
      );
    }
    return super.noSuchMethod(invocation);
  }

  @override
  ui.SemanticsUpdate build() {
    // The native bridge receives incremental updates and rejects nodes that
    // cannot be reached from the root after applying the current update.
    final tree = binding.tree..addAll(_children);
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in tree[id] ?? const <int>[]) {
        visit(child);
      }
    }

    visit(0);
    binding.unreachableNodes.addAll(
      _children.keys.where((id) => !reachable.contains(id)),
    );
    tree.removeWhere((id, _) => !reachable.contains(id));
    return _delegate.build();
  }
}
