import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/services/linux_system_proxy.dart';

void main() {
  late Directory directory;
  late File journal;
  late _DesktopSettings settings;
  late LinuxSystemProxy proxy;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nekoproxy-proxy-');
    journal = File('${directory.path}/proxy.json');
    settings = _DesktopSettings();
    proxy = LinuxSystemProxy(journal, settings);
  });

  tearDown(() => directory.delete(recursive: true));

  test('recovers prior PAC and unset keys after application restart', () async {
    final before = Map.of(settings.values);
    expect((await proxy.enable(2080)).ok, isTrue);
    expect(settings.values['mode'], 'manual');
    expect(settings.values['port'], '2080');
    expect(await journal.exists(), isTrue);

    final restarted = LinuxSystemProxy(journal, settings);
    expect((await restarted.restoreIfOwned()).ok, isTrue);
    expect(settings.values, before);
    expect(await journal.exists(), isFalse);
  });

  test('rolls back already written keys on partial failure', () async {
    final before = Map.of(settings.values);
    settings.failOnceOn = 'port';
    expect((await proxy.enable(2080)).ok, isFalse);
    expect(settings.values, before);
    expect(await journal.exists(), isFalse);
  });

  test(
    'preserves settings changed externally and restores owned keys',
    () async {
      expect((await proxy.enable(2080)).ok, isTrue);
      settings.values['mode'] = 'none';
      settings.values['host'] = 'external.example';
      expect((await proxy.disable()).ok, isTrue);
      expect(settings.values, {
        'mode': 'none',
        'host': 'external.example',
        'pac': 'https://example.org/proxy.pac',
      });
    },
  );

  test('keeps the journal when a rollback fails and retries later', () async {
    expect((await proxy.enable(2080)).ok, isTrue);
    settings.failOnceOn = 'host';
    expect((await proxy.disable()).ok, isFalse);
    expect(await journal.exists(), isTrue);
    expect((await proxy.disable()).ok, isTrue);
    expect(settings.values['host'], 'previous.example');
    expect(await journal.exists(), isFalse);
  });
}

class _DesktopSettings implements LinuxProxySettings {
  @override
  final id = 'test-desktop';

  final values = {
    'host': 'previous.example',
    'mode': 'auto',
    'pac': 'https://example.org/proxy.pac',
  };
  String? failOnceOn;

  @override
  Future<bool> available() async => true;

  @override
  Map<String, String> valuesFor(int port) => {
    'host': '127.0.0.1',
    'port': '$port',
    'mode': 'manual',
  };

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (failOnceOn == key) {
      failOnceOn = null;
      throw const FileSystemException('setting is locked');
    }
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> reload() async {}
}
