import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/domain/profile_parser.dart';

void main() {
  test('大订阅后台解析保留元数据、去重顺序和节点归属', () async {
    final links = List.generate(
      800,
      (index) => 'trojan://sample@node-$index.example:443#Node-$index',
    );
    final content = [...links, '${links.first}-duplicate'].join('\n');
    const headers = SubscriptionHeaders(
      userInfo: 'upload=1024; download=2048; total=8192',
      updateInterval: '2',
    );
    final profile = await ProfileParser.parseInBackground(
      content,
      headers: headers,
      subscriptionId: 'group',
    );
    expect(profile.nodes, hasLength(800));
    expect(profile.nodes.first.name, 'Node-0');
    expect(profile.nodes.last.name, 'Node-799');
    expect(profile.nodes.map((node) => node.subscriptionId).toSet(), {'group'});
    expect(profile.usage, 3072);
    expect(profile.totalBytes, 8192);
    expect(profile.updateIntervalMinutes, 120);
  });

  group('ProfileParser links', () {
    test('parses shadowsocks link', () {
      final profile = ProfileParser.parse(
        'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@example.com:8388#Tokyo',
      );
      expect(profile.nodes, hasLength(1));
      final outbound = profile.nodes.single.outbound;
      expect(outbound['type'], 'shadowsocks');
      expect(outbound['server'], 'example.com');
      expect(outbound['server_port'], 8388);
      expect(outbound['method'], 'aes-256-gcm');
      expect(outbound['password'], 'password');
      expect(profile.nodes.single.name, 'Tokyo');
      expect(profile.nodes.single.tag, startsWith('node-'));
    });

    test('parses base64 encoded link list', () {
      const links =
          '[Nodes]\r\n'
          'trojan://secret@example.org:443?sni=example.org#Node%20A\n'
          'vless://00000000-0000-0000-0000-000000000000@example.net:443?security=tls#Node%20B';
      final encoded = base64.encode(utf8.encode(links));
      final profile = ProfileParser.parse(encoded);
      expect(profile.format, 'base64');
      expect(profile.nodes, hasLength(2));
      expect(profile.nodes.first.outbound['type'], 'trojan');
      expect(profile.nodes.last.outbound['type'], 'vless');
    });

    test('parses vmess json link', () {
      final payload = base64.encode(
        utf8.encode(
          jsonEncode({
            'v': '2',
            'ps': 'VMess Node',
            'add': 'vm.example.com',
            'port': '8443',
            'id': '11111111-2222-3333-4444-555555555555',
            'aid': '0',
            'scy': 'auto',
            'net': 'ws',
            'host': 'cdn.example.com',
            'path': '/ws',
            'tls': 'tls',
            'sni': 'cdn.example.com',
          }),
        ),
      );
      final profile = ProfileParser.parse('vmess://$payload');
      final outbound = profile.nodes.single.outbound;
      expect(outbound['type'], 'vmess');
      expect(outbound['server_port'], 8443);
      expect(outbound['transport'], isA<Map>());
      expect((outbound['transport'] as Map)['type'], 'ws');
      expect((outbound['tls'] as Map)['enabled'], isTrue);
    });

    test('drops duplicate outbounds from the same subscription', () {
      const links =
          'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@example.com:8388#Tokyo\n'
          'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@example.com:8388#Tokyo-mirror';
      final profile = ProfileParser.parse(base64.encode(utf8.encode(links)));
      expect(profile.nodes, hasLength(1));
      expect(profile.nodes.single.name, 'Tokyo');
    });

    test('parses VLESS Reality links', () {
      final profile = ProfileParser.parse(
        'vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443'
        '?security=reality&encryption=none'
        '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        '&headerType=none&fp=edge&type=tcp&flow=xtls-rprx-vision'
        '&sni=www.example.com&sid=0123456789abcdef#Reality',
      );
      final outbound = profile.nodes.single.outbound;
      expect(outbound['type'], 'vless');
      expect(outbound['flow'], 'xtls-rprx-vision');
      final tls = outbound['tls'] as Map;
      expect(tls['enabled'], isTrue);
      expect(tls['server_name'], 'www.example.com');
      expect((tls['utls'] as Map)['fingerprint'], 'edge');
      final reality = tls['reality'] as Map;
      expect(reality['enabled'], isTrue);
      expect(reality['public_key'], isNotEmpty);
      expect(reality['short_id'], '0123456789abcdef');
    });

    test('rejects Reality links without a public key', () {
      expect(
        () => ProfileParser.parse(
          'vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443'
          '?security=reality&encryption=none&sni=www.example.com#Broken',
        ),
        throwsA(
          isA<ParseException>().having(
            (e) => e.message,
            'message',
            contains('pbk'),
          ),
        ),
      );
    });

    test('reports unparsable links instead of silently dropping them', () {
      expect(
        () => ProfileParser.parse('ss://not-a-valid-link'),
        throwsA(isA<ParseException>()),
      );
    });

    test('URI 解码失败只跳过坏链接，错误提示不包含原始凭据', () {
      const good = 'trojan://example-password@example.invalid:443#%E4%B8%AD';
      for (final bad in [
        'vmess://fixture-private%',
        'trojan://fixture-private@example.invalid:443#%FF',
        'trojan://fixture-private@example.invalid:443?security=%FF',
      ]) {
        expect(ProfileParser.parse('$bad\n$good').nodes.single.name, '中');
        expect(
          () => ProfileParser.parse(bad),
          throwsA(
            isA<ParseException>()
                .having((error) => error.message, '提示', contains('节点链接均无法解析'))
                .having(
                  (error) => error.message,
                  '原始凭据',
                  isNot(contains('fixture-private')),
                ),
          ),
        );
      }
    });
  });

  group('ProfileParser sing-box json', () {
    test('数组和 outbounds 对象共用过滤规则', () {
      final entries = [
        {'type': 'trojan', 'tag': 'valid', 'server': 'example.invalid'},
        {'tag': 'missing-type'},
        {'type': 'trojan', 'tag': 42},
        {'type': 'direct', 'tag': 'built-in'},
        null,
      ];
      for (final value in [
        entries,
        {'outbounds': entries},
      ]) {
        expect(
          ProfileParser.parse(jsonEncode(value)).nodes.single.name,
          'valid',
        );
      }
      for (final value in [[], entries.skip(1).toList()]) {
        expect(
          () => ProfileParser.parse(jsonEncode(value)),
          throwsA(isA<ParseException>()),
        );
      }
    });

    test('imports supported outbounds and skips built-ins', () {
      final profile = ProfileParser.parse(
        jsonEncode({
          'outbounds': [
            {'type': 'direct', 'tag': 'direct'},
            {
              'type': 'selector',
              'tag': 'proxy',
              'outbounds': ['node-a'],
            },
            {
              'type': 'hysteria2',
              'tag': 'node-a',
              'server': 'hy.example.com',
              'server_port': 443,
              'password': 'pw',
            },
          ],
        }),
      );
      expect(profile.nodes, hasLength(1));
      expect(profile.nodes.single.outbound['type'], 'hysteria2');
      expect(profile.nodes.single.outbound.containsKey('tag'), isFalse);
    });

    test('imports sing-box json wrapped in base64', () {
      final payload = base64.encode(
        utf8.encode(
          jsonEncode({
            'outbounds': [
              {
                'type': 'trojan',
                'tag': 'encoded',
                'server': 'example.com',
                'server_port': 443,
                'password': 'pw',
              },
            ],
          }),
        ),
      );
      final profile = ProfileParser.parse(payload);
      expect(profile.nodes, hasLength(1));
      expect(profile.nodes.single.outbound['type'], 'trojan');
    });

    test('imports sing-box json array wrapped in base64', () {
      const json =
          '[{"type":"trojan","tag":"encoded","server":"example.invalid",'
          '"server_port":443,"password":"fixture-password"},'
          '{"type":"direct","tag":"built-in"}]';
      final plain = ProfileParser.parse(json, subscriptionId: 'group');
      final wrapped = ProfileParser.parse(
        base64.encode(utf8.encode(' \n$json\n ')),
        subscriptionId: 'group',
      );

      expect(wrapped.format, 'sing-box');
      expect(wrapped.nodes.single.name, plain.nodes.single.name);
      expect(wrapped.nodes.single.outbound, plain.nodes.single.outbound);
      expect(wrapped.nodes.single.subscriptionId, 'group');
    });

    test('keeps base64 json arrays with link-like text in JSON parsing', () {
      const json =
          '[{"type":"trojan","tag":"Line\u2028https://example.invalid",'
          '"server":"example.invalid","server_port":443,"password":"pw"}]';
      final wrapped = ProfileParser.parse(base64.encode(utf8.encode(json)));

      expect(wrapped.format, 'sing-box');
      expect(wrapped.nodes.single.name, 'Line\u2028https://example.invalid');
    });

    test('rejects configuration without usable outbounds', () {
      expect(
        () => ProfileParser.parse(
          '{"outbounds":[{"type":"direct","tag":"direct"}]}',
        ),
        throwsA(isA<ParseException>()),
      );
    });
  });

  group('ProfileParser boundaries', () {
    test('does not echo credentials from malformed subscription JSON', () {
      for (final content in [
        '{"password":"private-test-password",!}',
        base64.encode(utf8.encode('[{"password":"private-test-password"},!]')),
      ]) {
        expect(
          () => ProfileParser.parse(content),
          throwsA(
            isA<ParseException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('JSON 解析失败'),
                isNot(contains('private-test-password')),
              ),
            ),
          ),
        );
      }
    });

    test('rejects Clash YAML subscriptions', () {
      expect(
        () => ProfileParser.parse('proxies:\n  - name: a\n    type: ss'),
        throwsA(
          predicate((e) => e is ParseException && e.message.contains('Clash')),
        ),
      );
    });

    test('reads usage and expiry headers', () {
      final profile = ProfileParser.parse(
        'trojan://pw@example.com:443#Node',
        headers: const SubscriptionHeaders(
          userInfo:
              'upload=1024; download=2048; total=1048576; expire=1893456000',
          updateInterval: '12',
        ),
      );
      expect(profile.usage, 3072);
      expect(profile.totalBytes, 1048576);
      expect(profile.expireAt, isNotNull);
      expect(profile.updateIntervalMinutes, 720);
    });

    test('fingerprint ignores map key order', () {
      final a = ProfileParser.fingerprintOf({
        'type': 'ss',
        'server': 'a',
        'port': 1,
      });
      final b = ProfileParser.fingerprintOf({
        'port': 1,
        'server': 'a',
        'type': 'ss',
      });
      expect(a, b);
    });
  });
}
