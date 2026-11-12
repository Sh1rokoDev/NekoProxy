import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ExitInfo {
  const ExitInfo({
    required this.ip,
    required this.region,
    required this.provider,
    required this.checkedAt,
  });

  final String ip;
  final String region;
  final String provider;
  final DateTime checkedAt;

  factory ExitInfo.fromTrace(String content) {
    final fields = <String, String>{};
    for (final line in const LineSplitter().convert(content)) {
      final separator = line.indexOf('=');
      if (separator > 0) {
        fields[line.substring(0, separator)] = line
            .substring(separator + 1)
            .trim();
      }
    }
    final ip = fields['ip'];
    if (ip == null ||
        InternetAddress.tryParse(ip) == null ||
        !RegExp(r'^[a-zA-Z]{2}$').hasMatch(fields['loc'] ?? '')) {
      throw const FormatException('备用出口信息无效');
    }
    return ExitInfo(
      ip: ip,
      region: fields['loc'] ?? '',
      provider: '',
      checkedAt: DateTime.now(),
    );
  }
}

// Source catalog and staggered scheduling follow FlClash's outbound-IP probe.
const exitInfoUrls = [
  'https://www.cloudflare.com/cdn-cgi/trace',
  'https://api.ip.sb/geoip',
  'https://ipinfo.io/json',
  'https://ipwho.is',
  'https://get.geojs.io/v1/ip/geo.json',
  'https://api.country.is',
  'https://api.ipquery.io/?format=json',
  'https://ident.me/json',
];

const _providerWait = Duration(seconds: 3);
final _asnOnly = RegExp(r'^AS\d+$', caseSensitive: false);

ExitInfo parseExitInfo(Uri source, String body) {
  if (source.host == 'www.cloudflare.com') return ExitInfo.fromTrace(body);
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic> ||
      decoded['error'] != null ||
      decoded['success'] == false) {
    throw const FormatException('出口检测响应格式无效');
  }
  final ip = decoded['ip'];
  final location = decoded['location'];
  final country = switch (source.host) {
    'ipinfo.io' || 'api.country.is' => decoded['country'],
    'ident.me' => decoded['cc'],
    'api.ipquery.io' => location is Map ? location['country_code'] : null,
    _ => decoded['country_code'],
  };
  if (ip is! String ||
      InternetAddress.tryParse(ip) == null ||
      country is! String ||
      !RegExp(r'^[a-zA-Z]{2}$').hasMatch(country)) {
    throw const FormatException('出口地址或地区无效');
  }
  String text(Object? value) => value is String ? value.trim() : '';
  final network = switch (source.host) {
    'ipwho.is' => decoded['connection'],
    'api.ipquery.io' => decoded['isp'],
    _ => null,
  };
  final fields = network is Map<String, dynamic> ? network : decoded;
  final asn = switch (fields['asn']) {
    final int value => value,
    final String value => int.tryParse(
      value.trim().toUpperCase().replaceFirst(RegExp(r'^AS'), ''),
    ),
    _ => null,
  };
  // GeoJS uses 64512 as the placeholder for an unknown ASN.
  final geoJsUnknownAsn = source.host == 'get.geojs.io' && asn == 64512;
  final provider =
      [
            fields['isp'],
            fields['organization_name'],
            if (!geoJsUnknownAsn) fields['organization'],
            fields['org'],
            fields['asn_organization'],
          ]
          .map(text)
          .firstWhere(
            (name) => name.isNotEmpty && name.toLowerCase() != 'unknown',
            orElse: () => '',
          );
  final asnLabel = asn != null && asn > 0 && !geoJsUnknownAsn ? 'AS$asn' : '';
  return ExitInfo(
    ip: ip,
    region: [
      text(decoded['country']).isNotEmpty &&
              !RegExp(r'^[a-zA-Z]{2}$').hasMatch(text(decoded['country']))
          ? text(decoded['country'])
          : country.toUpperCase(),
      text(decoded['city']),
    ].where((part) => part.isNotEmpty).toSet().join(' · '),
    provider: [
      provider,
      if (asnLabel.isNotEmpty &&
          !RegExp('\\b$asnLabel\\b', caseSensitive: false).hasMatch(provider))
        asnLabel,
    ].where((part) => part.isNotEmpty).join(' · '),
    checkedAt: DateTime.now(),
  );
}

/// Owns and closes [client] after success, failure, or the shared deadline.
/// The controller also closes it when its connection or selected node changes.
Future<ExitInfo> fetchExitInfo(HttpClient client) async {
  final result = Completer<ExitInfo>();
  var next = 0;
  var active = 0;
  Object? lastError;
  ExitInfo? fallback;
  Timer? providerTimer;

  void completeFallback() {
    if (result.isCompleted) return;
    final answer = fallback;
    if (answer != null) {
      result.complete(answer);
    } else {
      result.completeError(lastError ?? const HttpException('出口检测失败'));
    }
  }

  Future<ExitInfo> probe(Uri uri) async {
    final request = await client.getUrl(uri);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('出口检测返回 HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 4096) {
        throw const FormatException('出口检测响应过大');
      }
      bytes.addAll(chunk);
    }
    return parseExitInfo(uri, utf8.decode(bytes));
  }

  void start() {
    if (result.isCompleted || active >= 3 || next >= exitInfoUrls.length) {
      return;
    }
    final uri = Uri.parse(exitInfoUrls[next++]);
    active++;
    unawaited(() async {
      try {
        final answer = await probe(uri);
        if (result.isCompleted) return;
        final provider = answer.provider;
        if (provider.isNotEmpty && !_asnOnly.hasMatch(provider)) {
          result.complete(answer);
        } else {
          // Keep a usable address while giving other sources time to identify
          // its network. Each candidate keeps its own IP and provider together.
          if (fallback == null ||
              (fallback?.provider.isEmpty == true && provider.isNotEmpty)) {
            fallback = answer;
          }
          providerTimer ??= Timer(_providerWait, completeFallback);
        }
      } catch (error) {
        lastError = error;
      } finally {
        active--;
        if (!result.isCompleted) {
          if (next == exitInfoUrls.length && active == 0) {
            completeFallback();
          } else {
            start();
          }
        }
      }
    }());
  }

  final stagger = Timer.periodic(
    const Duration(milliseconds: 800),
    (_) => start(),
  );
  try {
    start();
    return await result.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () => fallback ?? (throw TimeoutException('出口检测超时')),
    );
  } finally {
    stagger.cancel();
    providerTimer?.cancel();
    // Prevent closed-client completions from scheduling more sources.
    if (!result.isCompleted) result.completeError(TimeoutException('出口检测超时'));
    client.close(force: true);
  }
}
