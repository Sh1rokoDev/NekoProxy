import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/runtime/runtime_client.dart';
import 'package:nekoproxy/services/exit_info_service.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('服务归属按地址去重，拒绝不匹配的记录并保留超时前的结果', (tester) async {
    final client = _Client()
      ..addressResponses['/142.251.150.119'] = Future.value(
        _jsonResponse({
          'ip': '142.251.150.119',
          'location': {
            'country': 'United States',
            'country_code': 'US',
            'city': 'Mountain View',
          },
          'isp': {'isp': 'Google LLC', 'asn': 'AS15169'},
        }),
      )
      ..addressResponses['/1.1.1.1'] = Future.value(
        _jsonResponse({
          'ip': '8.8.8.8',
          'location': {'country_code': 'US'},
        }),
      );
    final pending = fetchServiceAddressInfo(client, [
      '142.251.150.119',
      '142.251.150.119',
      '1.1.1.1',
      '2606:4700:4700::1111',
      '192.168.0.1',
      'example.com',
    ]);
    await tester.pump(const Duration(seconds: 4));
    expect(client.requests.map((uri) => uri.path), [
      '/142.251.150.119',
      '/1.1.1.1',
      '/2606:4700:4700::1111',
    ]);
    expect(await pending, {
      '142.251.150.119': (
        region: 'United States · Mountain View',
        countryCode: 'US',
        provider: 'Google LLC · AS15169',
      ),
    });
    expect(client.closed, isTrue);
    client.response.complete(_Response(503, []));
    await tester.pump();
  });

  testWidgets('每800毫秒增加查询，并发不超过3，成功后停止调度', (tester) async {
    final trace = Completer<HttpClientResponse>();
    final client = _Client()..responses['www.cloudflare.com'] = trace.future;
    final pending = fetchExitInfo(client);
    expect(client.requests, hasLength(1));
    await tester.pump(const Duration(milliseconds: 800));
    expect(client.requests, hasLength(2));
    await tester.pump(const Duration(milliseconds: 800));
    expect(client.requests, hasLength(3));
    await tester.pump(const Duration(milliseconds: 800));
    expect(client.requests, hasLength(3));
    client.response.complete(
      _jsonResponse({'ip': '203.0.113.24', 'country_code': 'HK', 'isp': 'ISP'}),
    );
    await tester.pump();
    expect((await pending).ip, '203.0.113.24');
    expect(client.closed, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(client.requests, hasLength(3));
  });

  testWidgets('地区查询先返回时继续等待运营商数据', (tester) async {
    final client = _Client()
      ..responses['www.cloudflare.com'] = Future.value(
        _Response(200, [utf8.encode('ip=203.0.113.24\nloc=HK\n')]),
      );
    final pending = fetchExitInfo(client);
    await tester.pump();
    expect(client.closed, isFalse);
    client.response.complete(
      _jsonResponse({
        'ip': '203.0.113.24',
        'country_code': 'HK',
        'isp': 'Example ISP',
        'asn': 1234,
      }),
    );
    await tester.pump();
    expect((await pending).provider, 'Example ISP · AS1234');
    expect(client.closed, isTrue);
  });

  testWidgets('运营商查询超出等待窗口时仍保留出口地址和地区', (tester) async {
    final client = _Client()
      ..responses['www.cloudflare.com'] = Future.value(
        _Response(200, [utf8.encode('ip=203.0.113.24\nloc=HK\n')]),
      );
    final pending = fetchExitInfo(client);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    final info = await pending;
    expect(info.ip, '203.0.113.24');
    expect(info.region, 'HK');
    expect(info.provider, isEmpty);
    expect(client.closed, isTrue);
  });

  test('解析有效的IPv4和IPv6出口，校验无效响应', () {
    for (final ip in ['203.0.113.24', '2001:db8::1']) {
      final info = parseExitInfo(
        Uri.https('ipwho.is', '/'),
        jsonEncode({
          'success': true,
          'ip': ip,
          'country': '香港',
          'country_code': 'HK',
          'city': '香港',
          'connection': {'isp': 'ISP', 'asn': 1234},
        }),
      );
      expect(info.ip, ip);
      expect(info.region, '香港');
      expect(info.provider, 'ISP · AS1234');
    }
    expect(
      () => parseExitInfo(
        Uri.https('ipwho.is', '/'),
        '{"success":false,"ip":"203.0.113.24"}',
      ),
      throwsFormatException,
    );
    expect(
      () => parseExitInfo(
        Uri.https('ipwho.is', '/'),
        '{"ip":"invalid","country_code":"HK"}',
      ),
      throwsFormatException,
    );
  });

  test('检测使用传入客户端，拒绝HTTP错误及过大的响应', () async {
    final client = _Client();
    client.response.complete(
      _Response(200, [
        utf8.encode('{"country_code":"HK","ip":"203.0.113.24","isp":"ISP"}'),
      ]),
    );
    expect((await fetchExitInfo(client)).ip, '203.0.113.24');
    expect(client.uri, Uri.https('api.ip.sb', '/geoip'));
    expect(client.closed, isTrue);
    final failure = _Client()..response.complete(_Response(503, []));
    await expectLater(fetchExitInfo(failure), throwsA(isA<HttpException>()));
    final oversized = _Client()
      ..response.complete(_Response(200, [List.filled(65537, 32)]));
    await expectLater(fetchExitInfo(oversized), throwsFormatException);
  });

  test('查询源独立失败后继续竞速，取得有效结果立即关闭客户端', () async {
    final client = _Client()
      ..primaryError = const HandshakeException('test handshake failure');
    client.response.complete(
      _Response(200, [
        utf8.encode('{"ip":"203.0.113.24","country_code":"HK","isp":"ISP"}'),
      ]),
    );
    final result = await fetchExitInfo(client);
    expect(client.uri, Uri.https('api.ip.sb', '/geoip'));
    expect(result.ip, '203.0.113.24');
    expect(result.region, 'HK');
    expect(client.closed, isTrue);
    expect(() => ExitInfo.fromTrace('ip=203.0.113.24'), throwsFormatException);
  });

  test('识别不同查询源的运营商名称和 ASN，忽略未知占位值', () {
    ExitInfo parse(String host, Map<String, Object> fields) => parseExitInfo(
      Uri.https(host),
      jsonEncode({'ip': '203.0.113.24', 'country_code': 'HK', ...fields}),
    );
    expect(
      parse('api.ipquery.io', {
        'location': {'country_code': 'HK'},
        'isp': {'isp': 'Example ISP', 'org': 'Example Org', 'asn': 'AS1234'},
      }).provider,
      'Example ISP · AS1234',
    );
    expect(
      parse('ipwho.is', {
        'connection': {'org': 'Example Org', 'asn': 1234},
      }).provider,
      'Example Org · AS1234',
    );
    expect(
      parse('get.geojs.io', {
        'organization_name': 'Unknown',
        'organization': 'AS64512 Unknown',
        'asn': 64512,
      }).provider,
      isEmpty,
    );
    expect(
      parse('get.geojs.io', {
        'organization_name': 'Example Org',
        'organization': 'AS1234 Example Org',
        'asn': 1234,
      }).provider,
      'Example Org · AS1234',
    );
    expect(
      parse('api.ip.sb', {'asn_organization': 'Example Org'}).provider,
      'Example Org',
    );
  });

  test('FlClash查询源按各自字段解析，拒绝缺失地区与错误响应', () {
    final samples = <String, String>{
      'https://www.cloudflare.com/cdn-cgi/trace': 'ip=203.0.113.24\nloc=HK\n',
      'https://api.ip.sb/geoip': '{"ip":"203.0.113.24","country_code":"HK"}',
      'https://ipinfo.io/json': '{"ip":"203.0.113.24","country":"HK"}',
      'https://ipwho.is': '{"ip":"203.0.113.24","country_code":"HK"}',
      'https://get.geojs.io/v1/ip/geo.json':
          '{"ip":"203.0.113.24","country_code":"HK"}',
      'https://api.country.is': '{"ip":"203.0.113.24","country":"HK"}',
      'https://api.ipquery.io/?format=json':
          '{"ip":"203.0.113.24","location":{"country_code":"HK"}}',
      'https://ident.me/json': '{"ip":"203.0.113.24","cc":"HK"}',
    };
    expect(samples.keys, exitInfoUrls);
    for (final entry in samples.entries) {
      expect(parseExitInfo(Uri.parse(entry.key), entry.value).region, 'HK');
    }
    expect(
      () => parseExitInfo(
        Uri.https('api.ip.sb', '/geoip'),
        '{"ip":"203.0.113.24"}',
      ),
      throwsFormatException,
    );
  });

  test('链式代理分别查询 WireGuard 对端和最终出口的地区', () async {
    final exitClient = _Client()
      ..responses['api.ip.sb'] = Future.value(
        _jsonResponse({
          'ip': '203.0.113.24',
          'country': 'Hong Kong',
          'country_code': 'HK',
          'isp': 'Example ISP',
        }),
      );
    final endpointClient = _Client();
    final nextExitClient = _Client();
    final nextEndpointClient = _Client();
    final key = base64Encode(List.filled(32, 2));
    final controller = AppController()
      ..running = true
      ..runtime = _Runtime()
      ..snapshot = AppSnapshot(
        settings: AppSettings(),
        subscriptions: [],
        outboundMode: OutboundMode.wireGuardProxy,
        wireGuardProfileId: 'wg',
        wireGuardProfiles: [
          WireGuardProfile(
            id: 'wg',
            name: '一级隧道',
            configuration:
                '''
[Interface]
PrivateKey = $key
Address = 10.0.0.2/24
[Peer]
PublicKey = $key
Endpoint = [2606:4700:4700::1111]:51820
AllowedIPs = 0.0.0.0/0
''',
          ),
        ],
      );
    addTearDown(controller.dispose);
    await HttpOverrides.runWithHttpOverrides(
      () async {
        final refresh = controller.refreshExitInfo();
        expect(endpointClient.requests.single.path, '/2606:4700:4700::1111');
        endpointClient.response.complete(
          _jsonResponse({
            'ip': '2606:4700:4700::1111',
            'location': {'country': 'China', 'country_code': 'CN'},
          }),
        );
        await refresh;
        expect(controller.wireGuardEndpointRegion, 'China');
        expect(controller.exitInfo?.region, 'Hong Kong');
        expect(endpointClient.closed, isTrue);

        final nextRefresh = controller.refreshExitInfo();
        await controller.disconnect();
        expect(nextExitClient.closed, isTrue);
        expect(nextEndpointClient.closed, isTrue);
        nextExitClient.response.complete(_Response(503, []));
        nextEndpointClient.response.complete(
          _jsonResponse({
            'ip': '2606:4700:4700::1111',
            'location': {'country_code': 'US'},
          }),
        );
        await nextRefresh;
        expect(controller.wireGuardEndpointRegion, isNull);
      },
      _ClientQueueOverride(
        [
          exitClient,
          endpointClient,
          nextExitClient,
          nextEndpointClient,
        ].iterator,
      ),
    );
  });

  test('断开后丢弃未完成的出口检测，关闭客户端', () async {
    final client = _Client();
    final controller = AppController()
      ..running = true
      ..runtime = _Runtime();
    addTearDown(controller.dispose);
    final override = _HttpOverride(client);
    await HttpOverrides.runWithHttpOverrides(() async {
      final refresh = controller.refreshExitInfo();
      expect(controller.checkingExitInfo, isTrue);
      await controller.disconnect();
      client.response.complete(
        _Response(200, [
          utf8.encode(
            '{"success":true,"country_code":"HK","ip":"203.0.113.24"}',
          ),
        ]),
      );
      await refresh;
      expect(client.closed, isTrue);
      expect(controller.exitInfo, isNull);
      expect(controller.exitInfoError, isNull);
      expect(controller.checkingExitInfo, isFalse);
    }, override);
  });

  test('重复刷新只接收最新结果，销毁时取消请求', () async {
    final first = _Client();
    final second = _Client();
    final third = _Client();
    final controller = AppController()..running = true;
    final clients = [first, second, third].iterator;
    await HttpOverrides.runWithHttpOverrides(() async {
      final oldRequest = controller.refreshExitInfo();
      final newRequest = controller.refreshExitInfo();
      expect(first.closed, isTrue);
      second.response.complete(
        _Response(200, [
          utf8.encode(
            '{"success":true,"country_code":"HK","ip":"203.0.113.25"}',
          ),
        ]),
      );
      await newRequest;
      first.response.complete(
        _Response(200, [
          utf8.encode(
            '{"success":true,"country_code":"HK","ip":"203.0.113.24"}',
          ),
        ]),
      );
      await oldRequest;
      expect(controller.exitInfo?.ip, '203.0.113.25');
      final lastRequest = controller.refreshExitInfo();
      controller.dispose();
      third.response.complete(
        _Response(200, [
          utf8.encode(
            '{"success":true,"country_code":"HK","ip":"203.0.113.26"}',
          ),
        ]),
      );
      await lastRequest;
      expect(third.closed, isTrue);
      expect(controller.exitInfo, isNull);
    }, _ClientQueueOverride(clients));
  });
}

class _ClientQueueOverride extends HttpOverrides {
  _ClientQueueOverride(this.clients);
  final Iterator<HttpClient> clients;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients.moveNext();
    return clients.current;
  }
}

class _HttpOverride extends HttpOverrides {
  _HttpOverride(this.client);
  final HttpClient client;
  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

class _Client implements HttpClient {
  final requests = <Uri>[];
  final responses = <String, Future<HttpClientResponse>>{};
  final addressResponses = <String, Future<HttpClientResponse>>{};
  Object? primaryError;
  final response = Completer<HttpClientResponse>();
  Uri? uri;
  bool closed = false;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    uri = url;
    if (url.host == 'www.cloudflare.com' && primaryError != null) {
      throw primaryError!;
    }
    return _Request(
      addressResponses[url.path] ?? responses[url.host] ?? response.future,
    );
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  set connectionTimeout(Duration? value) {}
  @override
  set findProxy(String Function(Uri)? value) {}
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

_Response _jsonResponse(Map<String, Object> fields) =>
    _Response(200, [utf8.encode(jsonEncode(fields))]);

class _Request implements HttpClientRequest {
  _Request(this.response);
  final Future<HttpClientResponse> response;
  @override
  HttpHeaders get headers => _Headers();
  @override
  Future<HttpClientResponse> close() => response;
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.chunks);
  @override
  final int statusCode;
  final List<List<int>> chunks;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable(chunks).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Runtime implements RuntimeClient {
  @override
  Future<void> shutdown() async {}
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
