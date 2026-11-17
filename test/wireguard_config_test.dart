import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/domain/config_compiler.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/services/backup_service.dart';

final _privateKey = base64Encode(List.filled(32, 1));
final _publicKey = base64Encode(List.filled(32, 2));

String _configuration(String allowed) =>
    '''
[Interface]
PrivateKey = $_privateKey
Address = 10.10.0.2/24, fd00::2/64
DNS = 10.10.0.53, fd00::53, lab.example

[Peer]
PublicKey = $_publicKey
Endpoint = 192.0.2.1:53
AllowedIPs = $allowed
PersistentKeepalive = 25
''';

AppSnapshot _snapshot(OutboundMode mode, String allowed) => AppSnapshot.empty()
  ..outboundMode = mode
  ..wireGuardProfileId = 'wg'
  ..wireGuardProfiles = [
    WireGuardProfile(
      id: 'wg',
      name: 'VPS',
      configuration: _configuration(allowed),
    ),
  ];

CompiledConfig _compile(
  AppSnapshot snapshot,
  CompileTarget target, {
  bool testOnly = false,
}) => ConfigCompiler.compile(
  snapshot,
  target: target,
  cachePath: 'cache.db',
  testOnly: testOnly,
);

void main() {
  test(
    'WireGuard backups require a password and restore the original key',
    () async {
      final snapshot = _snapshot(OutboundMode.wireGuard, '0.0.0.0/0');
      await expectLater(
        BackupService.export(snapshot),
        throwsA(isA<BackupPasswordException>()),
      );
      final backup = await BackupService.export(
        snapshot,
        password: 'test-password',
      );
      expect(backup, isNot(contains(_privateKey)));
      final restored = await BackupService.import(
        backup,
        password: 'test-password',
      );
      expect(
        restored.wireGuardProfile?.configuration,
        snapshot.wireGuardProfile?.configuration,
      );
    },
  );
  test('normalizes WireGuard routes, preserves multi-peer and DNS fields', () {
    final config = WireGuardConfig.parse('''
${_configuration('10.10.0.7/24, fd00::a/64')}
[Peer]
PublicKey = $_privateKey
Endpoint = [2001:db8::1]:51820
AllowedIPs = 172.16.0.7/16
''');
    expect(config.peers, hasLength(2));
    expect(config.allowedIps, ['10.10.0.0/24', 'fd00::/64', '172.16.0.0/16']);
    expect(config.dns, ['10.10.0.53', 'fd00::53']);
    expect(config.searchDomains, ['lab.example']);
    expect(config.firstEndpoint, '192.0.2.1:53');
  });

  test('invalid profiles report errors without copying input', () {
    for (final config in [
      _configuration('10.10.0.0/33'),
      _configuration('0.0.0.0/0')
          .replaceFirst('192.0.2.1:53', '192.0.2.1:65536'),
      _configuration('0.0.0.0/0').replaceFirst('Address = ', 'PostUp = '),
    ]) {
      expect(
        () => WireGuardConfig.parse(config),
        throwsA(
          isA<FormatException>().having(
            (e) => e.toString().contains(_privateKey),
            'contains key',
            false,
          ),
        ),
      );
    }
  });

  test(
    'standalone builds TUN with profile routes without proxy subscriptions',
    () {
      final snapshot = _snapshot(
        OutboundMode.wireGuard,
        '10.10.0.0/24, fd00::/64',
      )..settings.tunOrDefault.ipv6 = true;
      for (final target in CompileTarget.values) {
        final compiled = _compile(snapshot, target);
        expect(compiled.hasTunInbound, isTrue);
        expect(compiled.nodeTags, isEmpty);
        final tun = (compiled.json['inbounds'] as List).cast<Map>().singleWhere(
          (inbound) => inbound['type'] == 'tun',
        );
        expect(tun['route_address'], ['10.10.0.0/24', 'fd00::/64']);
        expect(tun['address'], contains('fdfe:dcba:9876::1/126'));
        expect((compiled.json['dns'] as Map)['strategy'], 'prefer_ipv4');
        expect(jsonEncode(compiled.redactedJson), isNot(contains(_privateKey)));
        expect(compiled.encoded, contains(_privateKey));
      }
    },
  );

  test('standalone takes IPv6 from the profile even when sing-box IPv6 is disabled', () {
    final snapshot = _snapshot(OutboundMode.wireGuard, '0.0.0.0/0, ::/0');
    for (final target in CompileTarget.values) {
      final compiled = _compile(snapshot, target);
      final tun = (compiled.json['inbounds'] as List).cast<Map>().singleWhere(
        (inbound) => inbound['type'] == 'tun',
      );
      expect(tun['route_address'], ['0.0.0.0/0', '::/0']);
      expect(tun['address'], contains('fdfe:dcba:9876::1/126'));
      expect((compiled.json['dns'] as Map)['strategy'], 'prefer_ipv4');
    }
  });

  test('standalone requires an IPv6 interface address to advertise IPv6', () {
    final snapshot = _snapshot(OutboundMode.wireGuard, '0.0.0.0/0, ::/0');
    final profile = snapshot.wireGuardProfiles.single;
    snapshot.settings.tunOrDefault.ipv6 = true;
    snapshot.wireGuardProfiles = [
      WireGuardProfile(
        id: profile.id,
        name: profile.name,
        configuration: profile.configuration.replaceFirst(', fd00::2/64', ''),
      ),
    ];
    final compiled = _compile(snapshot, CompileTarget.windows);
    expect((compiled.json['dns'] as Map)['strategy'], 'ipv4_only');
    final tun = (compiled.json['inbounds'] as List).cast<Map>().singleWhere(
      (inbound) => inbound['type'] == 'tun',
    );
    expect(tun['address'], ['172.19.0.1/30']);
  });

  test('standalone keeps IPv6 when the profile has no IPv4 route', () {
    final snapshot = _snapshot(OutboundMode.wireGuard, '::/0');
    for (final target in CompileTarget.values) {
      final compiled = _compile(snapshot, target);
      final tun = (compiled.json['inbounds'] as List).cast<Map>().singleWhere(
        (inbound) => inbound['type'] == 'tun',
      );
      expect(tun['route_address'], ['::/0']);
      expect(tun['address'], contains('fdfe:dcba:9876::1/126'));
      expect((compiled.json['dns'] as Map)['strategy'], 'ipv6_only');
    }
  });

  test('combined retains selector and wires nodes and direct DNS through the profile', () {
    final snapshot = _snapshot(OutboundMode.wireGuardProxy, '0.0.0.0/0');
    snapshot.subscriptions.add(
      Subscription(
        id: 'p',
        name: 'proxy',
        nodes: [
          ProxyNode(
            id: 'a',
            tag: 'a',
            name: 'a',
            outbound: {
              'type': 'http',
              'server': 'node.example.com',
              'server_port': 8080,
            },
          ),
        ],
      ),
    );
    final compiled = _compile(snapshot, CompileTarget.windows);
    final out = {
      for (final item in (compiled.json['outbounds'] as List).cast<Map>())
        item['tag']: item,
    };
    expect(compiled.hasTunInbound, isFalse);
    expect(out['direct']?['protect_windows'], isNull);
    expect(out['proxy']?['outbounds'], ['node-a']);
    expect(out['node-a']?['detour'], 'direct');
    expect(out['node-a']?['domain_resolver'], {'server': 'dns-direct'});
    final servers = ((compiled.json['dns'] as Map)['servers'] as List)
        .cast<Map>();
    expect(
      servers.singleWhere((s) => s['tag'] == 'dns-proxy')['detour'],
      'proxy',
    );
    expect(
      servers.singleWhere((s) => s['tag'] == 'dns-direct')['detour'],
      'direct',
    );
    final offline = _compile(snapshot, CompileTarget.windows, testOnly: true);
    expect(offline.hasTunInbound, isFalse);
    expect(offline.encoded, isNot(contains('protect_windows')));
    expect(offline.encoded, isNot(contains('block_uncovered')));
  });

  test('equivalent /1 routes do not trigger Windows system protection', () {
    final snapshot = _snapshot(
      OutboundMode.wireGuard,
      '0.0.0.0/1, 128.0.0.0/1',
    );
    expect(
      _compile(snapshot, CompileTarget.windows).encoded,
      isNot(contains('protect_windows')),
    );
  });

  test(
    'standalone keeps Windows protection for single-peer default routes',
    () {
      final snapshot = _snapshot(OutboundMode.wireGuard, '0.0.0.0/0');
      final windows = _compile(snapshot, CompileTarget.windows);
      final android = _compile(snapshot, CompileTarget.android);
      expect(windows.hasTunInbound, isTrue);
      expect(windows.encoded, contains('protect_windows'));
      expect(android.encoded, isNot(contains('protect_windows')));
    },
  );

  test('outbound settings round trip and old snapshots default to proxy', () {
    final snapshot = _snapshot(OutboundMode.wireGuard, '0.0.0.0/0');
    final restored = AppSnapshot.fromJson(snapshot.toJson());
    expect(restored.outboundMode, OutboundMode.wireGuard);
    expect(restored.wireGuardProfile?.name, 'VPS');
    final old = snapshot.toJson()
      ..remove('outboundMode')
      ..remove('chainProxyEnabled')
      ..remove('standaloneOutbound')
      ..remove('wireGuardGroups')
      ..remove('wireGuardProfileId')
      ..remove('wireGuardProfiles');
    expect(AppSnapshot.fromJson(old).outboundMode, OutboundMode.proxy);
  });

  test('migrates flat profiles without changing IDs or the selected stage', () {
    final old = _snapshot(OutboundMode.wireGuardProxy, '0.0.0.0/0').toJson()
      ..remove('chainProxyEnabled')
      ..remove('standaloneOutbound')
      ..remove('wireGuardGroups');
    final profiles = (old['wireGuardProfiles'] as List).cast<Map>();
    profiles.single.remove('groupId');
    final migrated = AppSnapshot.fromJson(old);
    expect(migrated.chainProxyEnabled, isTrue);
    expect(migrated.standaloneOutbound, StandaloneOutbound.singBox);
    expect(migrated.wireGuardGroups.single.id, WireGuardGroup.legacy.id);
    expect(migrated.wireGuardProfile?.id, 'wg');
    expect(migrated.wireGuardProfile?.groupId, WireGuardGroup.legacy.id);
  });
}
