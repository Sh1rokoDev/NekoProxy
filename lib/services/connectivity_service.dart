import 'dart:async';
import 'dart:io';

import 'exit_info_service.dart';

enum ServiceCheckStatus { pending, checking, available, failed }

class ConnectivityService {
  const ConnectivityService({
    required this.id,
    required this.name,
    required this.url,
    this.featured = false,
    this.useGet = false,
  });

  final String id;
  final String name;
  final String url;
  final bool featured;
  final bool useGet;

  String get host => Uri.parse(url).host;
}

const connectivityServices = <ConnectivityService>[
  ConnectivityService(
    id: 'google',
    name: 'Google',
    url: 'https://www.google.com/generate_204',
    featured: true,
    useGet: true,
  ),
  ConnectivityService(
    id: 'github',
    name: 'GitHub',
    url: 'https://github.com/',
    featured: true,
  ),
  ConnectivityService(
    id: 'youtube',
    name: 'YouTube',
    url: 'https://www.youtube.com/generate_204',
    featured: true,
    useGet: true,
  ),
  ConnectivityService(
    id: 'chatgpt',
    name: 'ChatGPT',
    url: 'https://chatgpt.com/',
    featured: true,
  ),
  ConnectivityService(id: 'claude', name: 'Claude', url: 'https://claude.ai/'),
  ConnectivityService(
    id: 'gemini',
    name: 'Gemini',
    url: 'https://gemini.google.com/',
  ),
  ConnectivityService(
    id: 'netflix',
    name: 'Netflix',
    url: 'https://www.netflix.com/',
  ),
  ConnectivityService(
    id: 'disney',
    name: 'Disney+',
    url: 'https://www.disneyplus.com/',
  ),
  ConnectivityService(
    id: 'primevideo',
    name: 'Prime Video',
    url: 'https://www.primevideo.com/',
  ),
  ConnectivityService(
    id: 'spotify',
    name: 'Spotify',
    url: 'https://open.spotify.com/',
  ),
  ConnectivityService(
    id: 'tiktok',
    name: 'TikTok',
    url: 'https://www.tiktok.com/',
  ),
  ConnectivityService(
    id: 'discord',
    name: 'Discord',
    url: 'https://discord.com/',
  ),
  ConnectivityService(
    id: 'bilibili',
    name: 'bilibili',
    url: 'https://www.bilibili.com/',
  ),
];

class ServiceCheckResult {
  const ServiceCheckResult({
    required this.status,
    this.latencyMs,
    this.address,
    this.addressInfo,
    this.error,
    this.checkedAt,
    this.viaProxy = false,
    this.viaTun = false,
  });

  final ServiceCheckStatus status;
  final int? latencyMs;
  final String? address;
  final IpAttribution? addressInfo;
  final String? error;
  final DateTime? checkedAt;
  final bool viaProxy;
  final bool viaTun;

  bool get isPending => status == ServiceCheckStatus.pending;
  bool get isChecking => status == ServiceCheckStatus.checking;
  bool get isAvailable => status == ServiceCheckStatus.available;
  bool get isFailed => status == ServiceCheckStatus.failed;

  ServiceCheckResult withAddressInfo(IpAttribution info) => ServiceCheckResult(
    status: status,
    latencyMs: latencyMs,
    address: address,
    addressInfo: info,
    error: error,
    checkedAt: checkedAt,
    viaProxy: viaProxy,
    viaTun: viaTun,
  );
}

Future<ServiceCheckResult> probeConnectivityService(
  ConnectivityService service, {
  required bool viaProxy,
  required int proxyPort,
  bool viaTun = false,
  String username = '',
  String password = '',
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 4)
    ..userAgent = 'NekoProxy/1.0';
  if (viaProxy) {
    client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    if (username.isNotEmpty || password.isNotEmpty) {
      client.addProxyCredentials(
        '127.0.0.1',
        proxyPort,
        'Basic',
        HttpClientBasicCredentials(username, password),
      );
    }
  }
  final stopwatch = Stopwatch()..start();
  try {
    return await _probe(
      service,
      client,
      stopwatch,
      viaProxy,
      viaTun,
    ).timeout(const Duration(seconds: 12));
  } on TimeoutException {
    return ServiceCheckResult(
      status: ServiceCheckStatus.failed,
      error: '超时',
      checkedAt: DateTime.now(),
      viaProxy: viaProxy,
      viaTun: viaTun,
    );
  } on HandshakeException {
    return ServiceCheckResult(
      status: ServiceCheckStatus.failed,
      error: 'TLS 失败',
      checkedAt: DateTime.now(),
      viaProxy: viaProxy,
      viaTun: viaTun,
    );
  } on SocketException {
    return ServiceCheckResult(
      status: ServiceCheckStatus.failed,
      error: '连接失败',
      checkedAt: DateTime.now(),
      viaProxy: viaProxy,
      viaTun: viaTun,
    );
  } on HttpException {
    return ServiceCheckResult(
      status: ServiceCheckStatus.failed,
      error: 'HTTP 错误',
      checkedAt: DateTime.now(),
      viaProxy: viaProxy,
      viaTun: viaTun,
    );
  } catch (_) {
    return ServiceCheckResult(
      status: ServiceCheckStatus.failed,
      error: '检测失败',
      checkedAt: DateTime.now(),
      viaProxy: viaProxy,
      viaTun: viaTun,
    );
  } finally {
    client.close(force: true);
  }
}

Future<ServiceCheckResult> _probe(
  ConnectivityService service,
  HttpClient client,
  Stopwatch stopwatch,
  bool viaProxy,
  bool viaTun,
) async {
  final uri = Uri.parse(service.url);
  final addressFuture = _resolveAddress(uri.host);
  final request =
      await (service.useGet ? client.getUrl(uri) : client.openUrl('HEAD', uri))
          .timeout(const Duration(seconds: 8));
  request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
  request.followRedirects = false;
  final response = await request.close().timeout(const Duration(seconds: 8));
  final statusCode = response.statusCode;
  await response.drain<void>().timeout(const Duration(seconds: 3));
  stopwatch.stop();
  final address = await addressFuture;
  final checkedAt = DateTime.now();
  if (statusCode >= 500) {
    return ServiceCheckResult(
      status: ServiceCheckStatus.failed,
      error: 'HTTP $statusCode',
      address: address,
      checkedAt: checkedAt,
      viaProxy: viaProxy,
      viaTun: viaTun,
    );
  }
  return ServiceCheckResult(
    status: ServiceCheckStatus.available,
    latencyMs: stopwatch.elapsedMilliseconds,
    address: address,
    checkedAt: checkedAt,
    viaProxy: viaProxy,
    viaTun: viaTun,
  );
}

Future<String?> _resolveAddress(String host) async {
  try {
    final addresses = await InternetAddress.lookup(host)
        .timeout(const Duration(seconds: 3));
    for (final address in addresses) {
      if (address.type == InternetAddressType.IPv4) return address.address;
    }
    return addresses.isEmpty ? null : addresses.first.address;
  } catch (_) {
    return null;
  }
}
