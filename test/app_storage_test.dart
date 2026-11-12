import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/domain/models.dart';

void main() {
  group('Windows 状态密钥', skip: !Platform.isWindows, () {
    late AppPaths paths;
    late AppStorage storage;

    setUp(() async {
      final directory = await Directory.systemTemp.createTemp('neko-state-');
      addTearDown(() => directory.delete(recursive: true));
      paths = AppPaths.forDirectory(directory.path);
      storage = AppStorage(paths);
    });

    test('密钥损坏时保留原状态、备份和密钥，恢复密钥后可重新保存', () async {
      final snapshot = AppSnapshot.empty();
      snapshot.subscriptions.add(Subscription(id: 'original', name: '原分组'));
      await storage.save(snapshot);
      await storage.save(snapshot);
      final originalState = await paths.stateFile.readAsString();
      final backup = File('${paths.stateFile.path}.bak');
      final originalBackup = await backup.readAsString();
      final originalKey = await paths.stateKeyFile.readAsString();
      await paths.stateKeyFile.writeAsString('invalid-key');

      final loaded = await storage.load();
      expect(loaded.warning, isNotNull);
      await expectLater(storage.save(loaded.snapshot), throwsFormatException);
      expect(await paths.stateFile.readAsString(), originalState);
      expect(await backup.readAsString(), originalBackup);
      expect(await paths.stateKeyFile.readAsString(), 'invalid-key');

      await paths.stateKeyFile.writeAsString(originalKey);
      await storage.save((await storage.load()).snapshot);
      expect(
        (await storage.load()).snapshot.subscriptions.single.id,
        'original',
      );
    });

    test('加密状态缺少密钥时不生成新密钥', () async {
      await storage.save(AppSnapshot.empty());
      final originalState = await paths.stateFile.readAsString();
      await paths.stateKeyFile.delete();

      await expectLater(storage.save(AppSnapshot.empty()), throwsStateError);
      expect(await paths.stateFile.readAsString(), originalState);
      expect(await paths.stateKeyFile.exists(), isFalse);
    });

    test('旧版明文状态不导入，初始状态可以保存', () async {
      final snapshot = AppSnapshot.empty()
        ..subscriptions.add(Subscription(id: 'legacy', name: '旧分组'));
      final legacy = jsonEncode({...snapshot.toJson(), 'version': 1});
      await paths.stateFile.writeAsString(legacy);

      final loaded = await storage.load();
      expect(loaded.warning, contains('格式不受支持'));
      expect(loaded.snapshot.subscriptions, isEmpty);
      expect(await paths.stateFile.readAsString(), legacy);
      await storage.save(loaded.snapshot);
      expect((await storage.load()).warning, isNull);
    });

    test('旧版加密状态不导入，也不要求找回旧密钥', () async {
      final snapshot = AppSnapshot.empty()
        ..subscriptions.add(Subscription(id: 'legacy', name: '旧分组'));
      await storage.save(snapshot);
      final envelope = jsonDecode(await paths.stateFile.readAsString()) as Map;
      envelope['version'] = 1;
      await paths.stateFile.writeAsString(jsonEncode(envelope));
      await paths.stateKeyFile.delete();

      final loaded = await storage.load();
      expect(loaded.warning, contains('格式不受支持'));
      expect(loaded.snapshot.subscriptions, isEmpty);
      await storage.save(loaded.snapshot);
      expect((await storage.load()).warning, isNull);
    });

    test('密钥格式正确但验证失败时保护原状态', () async {
      await storage.save(AppSnapshot.empty());
      final originalState = await paths.stateFile.readAsString();
      final originalKey = await paths.stateKeyFile.readAsString();
      await paths.stateKeyFile.writeAsString(base64Encode(List.filled(32, 0)));

      expect((await storage.load()).warning, isNotNull);
      await expectLater(storage.save(AppSnapshot.empty()), throwsStateError);
      expect(await paths.stateFile.readAsString(), originalState);

      await paths.stateKeyFile.writeAsString(originalKey);
      expect((await storage.load()).warning, isNull);
      await storage.save(AppSnapshot.empty());
    });
  });

  test('导出备份保存在 userdata 下，并保留此前导出的文件', () async {
    final directory = await Directory.systemTemp.createTemp('neko-backup-');
    addTearDown(() => directory.delete(recursive: true));
    final storage = AppStorage(AppPaths.forDirectory(directory.path));
    final first = await storage.writeBackup('first');
    final second = await storage.writeBackup('second');

    expect(first.parent.parent.path, directory.path);
    expect(first.parent.path, second.parent.path);
    expect(first.path, isNot(second.path));
    expect(await first.readAsString(), 'first');
    expect(await second.readAsString(), 'second');
  });

  test('forDirectory 在安装目录内派生状态、密钥、runtime 与日志路径', () {
    final sep = Platform.pathSeparator;
    final base = 'C:\\Apps\\NekoProxy${sep}userdata';
    final paths = AppPaths.forDirectory(base);
    expect(paths.stateFile.path, '$base${sep}state.json');
    expect(paths.stateKeyFile.path, '$base${sep}state.key');
    expect(paths.runtime.path, '$base${sep}runtime');
    expect(paths.logFile.path, '$base${sep}runtime${sep}core.log');
  });
}
