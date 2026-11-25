import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/services/windows_system_proxy.dart';

void main() {
  const server = '127.0.0.1:2080';
  const applied = SystemProxySnapshot(
    proxyEnable: 1,
    proxyServer: server,
    proxyOverride: SystemProxySnapshot.loopbackOverride,
  );
  // Use the on-disk format from existing installations.
  final journal = SystemProxySnapshot.fromJson({
    'appliedServer': server,
    'proxyEnable': 0,
    'proxyServer': null,
    'proxyOverride': 'intranet',
    'autoConfigUrl': 'https://original.example/pac',
  });

  test('restart restores original settings including absent server', () {
    final result = journal.restoredSettings(applied);
    expect(result.proxyEnable, 0);
    expect(result.proxyServer, isNull);
    expect(result.proxyOverride, 'intranet');
    expect(result.autoConfigUrl, 'https://original.example/pac');
  });

  test('preserves edited bypass and PAC across recovery and re-enable', () {
    const edited = SystemProxySnapshot(
      proxyEnable: 1,
      proxyServer: server,
      proxyOverride: 'new-intranet',
      autoConfigUrl: 'https://new.example/pac',
    );
    final result = journal.restoredSettings(edited);
    expect(result.proxyEnable, 0);
    expect(result.proxyServer, isNull);
    expect(result.proxyOverride, edited.proxyOverride);
    expect(result.autoConfigUrl, edited.autoConfigUrl);
    final reapplied = result.withAppliedServer(server);
    expect(reapplied.restoredSettings(applied).toJson(), result.toJson());
  });

  test('keeps replacement manual proxy active and respects deleted bypass', () {
    const edited = SystemProxySnapshot(proxyEnable: 1, proxyServer: 'other:80');
    final result = journal.restoredSettings(edited);
    expect(result.proxyEnable, 1);
    expect(result.proxyServer, 'other:80');
    expect(result.proxyOverride, isNull);
    expect(result.autoConfigUrl, journal.autoConfigUrl);
  });
}
