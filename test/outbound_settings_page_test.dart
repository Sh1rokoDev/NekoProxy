import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/features/nodes/nodes_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

class _Controller extends AppController {
  int applied = 0;
  @override
  Future<void> applyOutboundSettings(
    OutboundMode mode,
    String? profileId,
    List<WireGuardProfile> profiles,
  ) async {
    applied++;
    snapshot
      ..outboundMode = mode
      ..wireGuardProfileId = profileId
      ..wireGuardProfiles = List.of(profiles);
  }
}

void main() {
  testWidgets(
    'advanced keeps a draft until applied, including on a narrow screen',
    (tester) async {
      tester.view
        ..physicalSize = const Size(320, 700)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = base64Encode(List.filled(32, 2));
      final controller = _Controller()
        ..snapshot.wireGuardProfiles = [
          WireGuardProfile(
            id: 'wg',
            name: '校园 VPS',
            configuration:
                '''
[Interface]
PrivateKey = $key
Address = 10.0.0.2/24
[Peer]
PublicKey = $key
Endpoint = 192.0.2.1:53
AllowedIPs = 0.0.0.0/0
''',
          ),
        ];
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(
            controller: controller,
            child: const Scaffold(body: NodesPage()),
          ),
        ),
      );
      expect(find.text('手动'), findsOneWidget);
      expect(find.text('自动'), findsOneWidget);
      expect(tester.takeException(), isNull);

      Future<void> editDraft() async {
        await tester.tap(find.byTooltip('高级'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('仅代理'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('仅 WireGuard').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('校园 VPS'));
        await tester.pumpAndSettle();
      }

      await editDraft();
      expect(controller.snapshot.outboundMode, OutboundMode.proxy);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(controller.applied, 0);
      expect(controller.snapshot.wireGuardProfileId, isNull);

      await editDraft();
      await tester.ensureVisible(find.text('应用出站设置'));
      await tester.tap(find.text('应用出站设置'));
      await tester.pumpAndSettle();
      expect(controller.applied, 1);
      expect(controller.snapshot.outboundMode, OutboundMode.wireGuard);
      expect(controller.snapshot.wireGuardProfileId, 'wg');
      expect(controller.canConnect, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
