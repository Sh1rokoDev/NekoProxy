import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/nodes/nodes_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('拖拽节点集合后保存可见分组顺序，写入失败时恢复顺序', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final first = _group('first', '订阅甲');
    final hidden = _group('hidden', '隐藏订阅', nodeName: '其他节点');
    final local = _group('local-group', '本地分组', isLocal: true);
    final last = _group('last', '订阅乙');
    final storage = _Storage();
    final controller = AppController()
      ..storage = storage
      ..snapshot = AppSnapshot(
        settings: AppSettings(),
        subscriptions: [first, hidden, local, last],
      );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

    final firstCard = find
        .descendant(
          of: find.byKey(ValueKey(first.id)),
          matching: find.byType(AnimatedContainer),
        )
        .first;
    final firstHandle = find.descendant(
      of: firstCard,
      matching: find.byIcon(Icons.drag_indicator_rounded),
    );
    final firstCloud = find.descendant(
      of: firstCard,
      matching: find.byIcon(Icons.cloud_outlined),
    );
    await tester.tap(find.text('订阅甲'));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(firstHandle).dx,
      lessThan(tester.getTopLeft(firstCloud).dx),
    );
    expect(tester.getCenter(firstHandle).dy, tester.getCenter(firstCard).dy);

    await tester.tap(find.byTooltip('搜索节点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '匹配');
    await tester.pumpAndSettle();
    expect(find.text('隐藏订阅'), findsNothing);
    expect(find.text('本地分组'), findsOneWidget);

    final handles = find.byIcon(Icons.drag_indicator_rounded);
    expect(handles, findsNWidgets(3));
    expect(tester.getCenter(firstHandle).dy, tester.getCenter(firstCard).dy);

    final start = tester.getCenter(find.byTooltip('拖拽调整节点集合顺序'));
    final end = Offset(start.dx, tester.getCenter(handles.first).dy - 55);
    await tester.timedDragFrom(start, end - start, const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(controller.snapshot.subscriptions.map((group) => group.id), [
      local.id,
      hidden.id,
      first.id,
      last.id,
    ]);
    final saved = AppSnapshot.fromJson(
      jsonDecode(storage.savedState ?? '') as Map<String, dynamic>,
    );
    expect(saved.subscriptions.map((group) => group.id), [
      local.id,
      hidden.id,
      first.id,
      last.id,
    ]);
    expect(
      tester.getTopLeft(find.text('本地分组')).dy,
      lessThan(tester.getTopLeft(find.text('订阅甲')).dy),
    );
    expect(
      tester.getTopLeft(find.text('订阅甲')).dy,
      lessThan(tester.getTopLeft(find.text('订阅乙')).dy),
    );

    storage.failSave = true;
    final mouseStart = tester.getCenter(handles.last);
    final mouseEnd = tester.getCenter(handles.first) - const Offset(0, 10);
    final mouseDrag = await tester.startGesture(
      mouseStart,
      kind: PointerDeviceKind.mouse,
    );
    for (var step = 1; step <= 20; step++) {
      await mouseDrag.moveTo(
        mouseStart + (mouseEnd - mouseStart) * (step / 20),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await mouseDrag.up();
    await tester.pumpAndSettle();

    expect(controller.error, startsWith('分组顺序保存失败'));
    expect(controller.snapshot.subscriptions, [local, hidden, first, last]);
  });

  testWidgets('拖拽 WireGuard 分组后保存顺序并保留隐藏分组的位置', (tester) async {
    const first = WireGuardGroup(id: 'wg-first', name: '匹配甲');
    const hidden = WireGuardGroup(id: 'wg-hidden', name: '隐藏');
    const last = WireGuardGroup(id: 'wg-last', name: '匹配乙');
    final storage = _Storage();
    final controller = AppController()
      ..storage = storage
      ..snapshot = AppSnapshot(
        settings: AppSettings(),
        subscriptions: [],
        wireGuardGroups: [first, hidden, last],
      );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: const Scaffold(body: NodesPage()),
        ),
      ),
    );

    await tester.tap(find.byTooltip('搜索节点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '匹配');
    await tester.pumpAndSettle();
    expect(find.text(hidden.name), findsNothing);

    final handles = find.byTooltip('拖拽调整 WireGuard 分组顺序');
    expect(handles, findsNWidgets(2));
    final start = tester.getCenter(handles.last);
    final end = tester.getCenter(handles.first) - const Offset(0, 40);
    await tester.timedDragFrom(start, end - start, const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final expectedIds = [last.id, hidden.id, first.id];
    expect(
      controller.snapshot.wireGuardGroups.map((group) => group.id),
      expectedIds,
    );
    final saved = AppSnapshot.fromJson(
      jsonDecode(storage.savedState ?? '') as Map<String, dynamic>,
    );
    expect(saved.wireGuardGroups.map((group) => group.id), expectedIds);
    expect(
      tester.getTopLeft(find.text(last.name)).dy,
      lessThan(tester.getTopLeft(find.text(first.name)).dy),
    );
  });
}

Subscription _group(
  String id,
  String name, {
  String nodeName = '匹配节点',
  bool isLocal = false,
}) => Subscription(
  id: id,
  name: name,
  url: isLocal ? '' : 'https://example.com/$id',
  nodes: [
    ProxyNode(
      id: '$id-node',
      tag: '$id-node',
      name: nodeName,
      subscriptionId: id,
      outbound: const {'type': 'direct'},
    ),
  ],
);

class _Storage extends AppStorage {
  _Storage() : super(AppPaths.forDirectory(Directory.systemTemp.path));

  String? savedState;
  bool failSave = false;

  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (failSave) throw const FileSystemException('写入失败');
    savedState = snapshot.encode();
  }
}
