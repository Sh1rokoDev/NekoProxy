import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/services/backup_service.dart';

void main() {
  final snapshot = AppSnapshot.empty()
    ..subscriptions.add(Subscription(id: 'sample', name: '测试分组'));

  test('当前无密码备份可以恢复', () async {
    final backup = await BackupService.export(snapshot);
    final restored = await BackupService.import(backup);
    expect(restored.toJson(), snapshot.toJson());
  });

  test('当前加密备份需要正确的密码', () async {
    final backup = await BackupService.export(
      snapshot,
      password: 'test-secret',
    );
    final restored = await BackupService.import(
      backup,
      password: 'test-secret',
    );
    expect(restored.toJson(), snapshot.toJson());
    await expectLater(
      BackupService.import(backup),
      throwsA(isA<BackupPasswordException>()),
    );
    await expectLater(
      BackupService.import(backup, password: 'wrong-password'),
      throwsA(isA<BackupPasswordException>()),
    );
    final damaged = jsonDecode(backup) as Map<String, dynamic>;
    damaged['nonce'] = '';
    await expectLater(
      BackupService.import(jsonEncode(damaged)),
      throwsA(
        isA<BackupException>().having(
          (error) => error.message,
          'message',
          '备份文件内容损坏',
        ),
      ),
    );
  });

  test('拒绝旧版备份和没有备份封装的状态数据', () async {
    final current = jsonDecode(await BackupService.export(snapshot)) as Map;
    for (final backup in [
      {...current, 'version': 1},
      {'app': 'nekoproxy-backup', 'version': 1},
      snapshot.toJson(),
      {
        ...current,
        'data': {...snapshot.toJson(), 'version': 1},
      },
    ]) {
      await expectLater(
        BackupService.import(jsonEncode(backup)),
        throwsA(isA<BackupException>()),
      );
    }
  });
}
