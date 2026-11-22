import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'models.dart';

class ParseException implements Exception {
  const ParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ParsedProfile {
  const ParsedProfile({
    required this.nodes,
    this.usage,
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expireAt,
    this.updateIntervalMinutes,
    this.format = 'unknown',
  });

  final List<ProxyNode> nodes;
  final int? usage;
  final int? uploadBytes;
  final int? downloadBytes;
  final int? totalBytes;
  final DateTime? expireAt;
  final int? updateIntervalMinutes;
  final String format;
}

class SubscriptionHeaders {
  const SubscriptionHeaders({
    this.userInfo,
    this.updateInterval,
    this.profileTitle,
  });

  final String? userInfo;
  final String? updateInterval;
  final String? profileTitle;

  factory SubscriptionHeaders.from(Map<String, String> headers) {
    String? pick(String key) {
      for (final entry in headers.entries) {
        if (entry.key.toLowerCase() == key.toLowerCase()) return entry.value;
      }
      return null;
    }

    return SubscriptionHeaders(
      userInfo: pick('subscription-userinfo'),
      updateInterval: pick('profile-update-interval'),
      profileTitle: pick('profile-title'),
    );
  }

  ({int? upload, int? download, int? total, DateTime? expire}) parseUserInfo() {
    final raw = userInfo;
    if (raw == null || raw.isEmpty) {
      return (upload: null, download: null, total: null, expire: null);
    }
    int? value(String key) {
      final match = RegExp('(?:^|;)\\s*$key\\s*=\\s*(\\d+)').firstMatch(raw);
      return match == null ? null : int.tryParse(match.group(1)!);
    }

    final expire = value('expire');
    return (
      upload: value('upload'),
      download: value('download'),
      total: value('total'),
      expire: expire == null || expire <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expire * 1000),
    );
  }
}

class ProfileParser {
  // Large profiles can take several UI frames to parse and deduplicate.
  static const _backgroundThreshold = 32 * 1024;

  static Future<ParsedProfile> parseInBackground(
    String content, {
    SubscriptionHeaders? headers,
    String? subscriptionId,
  }) async {
    if (content.length < _backgroundThreshold) {
      return parse(content, headers: headers, subscriptionId: subscriptionId);
    }
    return Isolate.run(
      () => parse(content, headers: headers, subscriptionId: subscriptionId),
      debugName: 'subscription parser',
    );
  }

  ProfileParser._();

  static final _supportedSchemes = {
    'ss',
    'vmess',
    'vless',
    'trojan',
    'hysteria2',
    'hy2',
    'hy',
    'tuic',
    'anytls',
    'socks',
    'socks5',
    'http',
    'https',
  };

  static ParsedProfile parse(
    String content, {
    SubscriptionHeaders? headers,
    String? subscriptionId,
  }) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) throw const ParseException('内容为空');

    if (_looksLikeClash(trimmed)) {
      throw const ParseException(
        '不支持 Clash/Mihomo 配置或订阅。请使用 sing-box、节点链接或 Base64 列表。',
      );
    }

    ParsedProfile result;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      result = _parseJson(trimmed, subscriptionId);
    } else {
      final decoded = _tryBase64Text(trimmed);
      if (decoded != null && _containsSupportedLinks(decoded)) {
        result = _parseLinkList(decoded, subscriptionId, format: 'base64');
      } else if (decoded != null &&
          (decoded.trimLeft().startsWith('{') ||
              decoded.trimLeft().startsWith('['))) {
        result = _parseJson(decoded.trim(), subscriptionId);
      } else if (_containsSupportedLinks(trimmed)) {
        result = _parseLinkList(trimmed, subscriptionId);
      } else {
        throw const ParseException('未识别到受支持的节点或 sing-box 配置');
      }
    }

    final info = headers?.parseUserInfo();
    final interval = int.tryParse(headers?.updateInterval ?? '');
    final hasUsage =
        info != null &&
        (info.upload != null || info.download != null || info.total != null);
    return ParsedProfile(
      nodes: result.nodes,
      usage: hasUsage ? (info.upload ?? 0) + (info.download ?? 0) : null,
      uploadBytes: info?.upload,
      downloadBytes: info?.download,
      totalBytes: info?.total,
      expireAt: info?.expire,
      updateIntervalMinutes: interval != null && interval > 0
          ? interval * 60
          : result.updateIntervalMinutes,
      format: result.format,
    );
  }

  static bool _looksLikeClash(String text) {
    if (RegExp(r'^\s*proxies\s*:', multiLine: true).hasMatch(text)) return true;
    if (RegExp(r'^\s*proxy-groups\s*:', multiLine: true).hasMatch(text)) {
      return true;
    }
    if (RegExp(r'^\s*rules\s*:', multiLine: true).hasMatch(text)) return true;
    return text.startsWith('mixed-port:') || text.startsWith('port:');
  }

  static bool _containsSupportedLinks(String text) => RegExp(
    r'^(?:' + _supportedSchemes.map(RegExp.escape).join('|') + r')://',
    caseSensitive: false,
    multiLine: true,
  ).hasMatch(text);

  static String? _tryBase64Text(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.length < 8 ||
        !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(compact)) {
      return null;
    }
    try {
      final normalized = base64Url.normalize(compact);
      final decoded = utf8.decode(base64.decode(normalized));
      return decoded.contains('://') || decoded.trimLeft().startsWith('{')
          ? decoded
          : null;
    } catch (_) {
      return null;
    }
  }

  static ParsedProfile _parseJson(String text, String? subscriptionId) {
    dynamic raw;
    try {
      raw = jsonDecode(text);
    } on FormatException catch (e) {
      throw ParseException('JSON 解析失败（字符位置 ${e.offset ?? 0}）');
    }

    final entries = switch (raw) {
      List() => raw,
      {'outbounds': final List outbounds} => outbounds,
      Map() => [raw],
      _ => throw const ParseException('JSON 根节点必须是对象或数组'),
    };
    final outbounds = entries
        .whereType<Map<String, dynamic>>()
        .where(_isUsableOutbound)
        .toList();
    if (outbounds.isEmpty) {
      throw const ParseException('sing-box JSON 中没有可导入的出站节点');
    }
    return _profileFromOutbounds(outbounds, subscriptionId, 'sing-box');
  }

  static bool _isUsableOutbound(Map<String, dynamic> outbound) {
    final type = outbound['type'];
    final tag = outbound['tag'];
    if (type is! String || tag is! String) return false;
    return !const {
      'direct',
      'block',
      'selector',
      'urltest',
      'dns',
    }.contains(type);
  }

  static ParsedProfile _profileFromOutbounds(
    List<Map<String, dynamic>> outbounds,
    String? subscriptionId,
    String format,
  ) {
    final nodes = <ProxyNode>[];
    for (final outbound in outbounds) {
      final tag = (outbound['tag'] as String).trim();
      final type = outbound['type'] as String;
      final node = ProxyNode(
        id: _newId(),
        tag: 'node-$tag',
        name: tag.isEmpty ? type : tag,
        outbound: _normalizeOutbound(outbound),
        subscriptionId: subscriptionId,
        createdAt: DateTime.now(),
      );
      nodes.add(node);
    }
    return ParsedProfile(nodes: _deduplicate(nodes), format: format);
  }

  static Map<String, dynamic> _normalizeOutbound(
    Map<String, dynamic> outbound,
  ) {
    final copy = Map<String, dynamic>.from(outbound);
    copy.remove('tag');
    return copy;
  }

  static ParsedProfile _parseLinkList(
    String text,
    String? subscriptionId, {
    String format = 'links',
  }) {
    final nodes = <ProxyNode>[];
    String? firstError;
    for (final line in const LineSplitter().convert(text)) {
      final value = line.trim();
      if (value.isEmpty || value.startsWith('#')) continue;
      try {
        final node = parseLink(value, subscriptionId: subscriptionId);
        if (node != null) nodes.add(node);
      } on ParseException catch (e) {
        firstError ??= e.message;
      }
    }
    if (nodes.isEmpty) {
      throw ParseException(
        firstError == null ? '没有可导入的节点链接' : '节点链接均无法解析：$firstError',
      );
    }
    return ParsedProfile(nodes: _deduplicate(nodes), format: format);
  }

  static ProxyNode? parseLink(String link, {String? subscriptionId}) {
    final uri = Uri.tryParse(link);
    if (uri == null || !uri.hasScheme) throw const ParseException('无效的节点链接');
    final scheme = uri.scheme.toLowerCase();
    final Map<String, dynamic> outbound;
    switch (scheme) {
      case 'ss':
        outbound = _parseShadowsocks(uri);
      case 'vmess':
        outbound = _parseVmess(link);
      case 'vless':
        outbound = _parseVless(uri);
      case 'trojan':
        outbound = _parseTrojan(uri);
      case 'hysteria2':
      case 'hy2':
      case 'hy':
        outbound = _parseHysteria2(uri);
      case 'tuic':
        outbound = _parseTuic(uri);
      case 'anytls':
        outbound = _parseAnyTls(uri);
      case 'socks':
      case 'socks5':
        outbound = _parseSocks(uri);
      case 'http':
      case 'https':
        outbound = _parseHttp(uri);
      default:
        throw ParseException('不支持的链接协议：$scheme');
    }
    final name = _displayName(uri, outbound);
    final tag = _safeTag(name);
    return ProxyNode(
      id: _newId(),
      tag: 'node-$tag',
      name: name,
      outbound: outbound,
      subscriptionId: subscriptionId,
      createdAt: DateTime.now(),
    );
  }

  static String _displayName(Uri uri, Map<String, dynamic> outbound) {
    if (uri.fragment.isNotEmpty) return _decodeComponent(uri.fragment);
    final server = outbound['server']?.toString() ?? '';
    final type = outbound['type']?.toString().toUpperCase() ?? 'NODE';
    return '$type $server';
  }

  static String _safeTag(String input) {
    final ascii = input.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-');
    final cleaned = ascii
        .replaceAll(RegExp('-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (cleaned.isNotEmpty) return cleaned;
    return '${DateTime.now().microsecondsSinceEpoch}';
  }

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_counter++}-${_randomSuffix()}';

  static int _counter = 0;
  // Imports may run on separate isolates with independent counters.
  static final _isolateSeed = Random.secure().nextInt(1 << 32);

  static String _randomSuffix() {
    final seed =
        DateTime.now().microsecondsSinceEpoch ^
        (_counter * 2654435761) ^
        _isolateSeed;
    return seed.toRadixString(36);
  }

  static void _require(bool condition, String message) {
    if (!condition) throw ParseException(message);
  }

  static int _port(Uri uri) {
    _require(uri.hasPort && uri.port > 0 && uri.port <= 65535, '端口无效');
    return uri.port;
  }

  static (String, String) _userInfo(Uri uri) {
    final raw = uri.userInfo;
    if (raw.isEmpty) return ('', '');
    final index = raw.indexOf(':');
    if (index < 0) return (_decodeComponent(raw), '');
    return (
      _decodeComponent(raw.substring(0, index)),
      _decodeComponent(raw.substring(index + 1)),
    );
  }

  static String _decodeComponent(String value) =>
      _decodeUriValue(() => Uri.decodeComponent(value));

  static Map<String, String> _queryParameters(Uri uri) =>
      _decodeUriValue(() => uri.queryParameters);

  static T _decodeUriValue<T>(T Function() decode) {
    try {
      return decode();
    } on ArgumentError {
      throw const ParseException('节点链接的百分号编码无效');
    } on FormatException {
      throw const ParseException('节点链接含有无效的 UTF-8 字符');
    }
  }

  static Map<String, dynamic> _parseShadowsocks(Uri uri) {
    var method = '';
    var password = '';
    var host = uri.host;
    var port = uri.port;

    if (host.isEmpty && uri.userInfo.isNotEmpty) {
      final decoded = _decodeBase64(uri.userInfo);
      final at = decoded.lastIndexOf('@');
      _require(at > 0, 'SS 链接格式无效');
      final credentials = decoded.substring(0, at).split(':');
      _require(credentials.length >= 2, 'SS 加密信息无效');
      method = credentials.first;
      password = credentials.sublist(1).join(':');
      final server = decoded.substring(at + 1);
      final lastColon = server.lastIndexOf(':');
      _require(lastColon > 0, 'SS 服务器地址无效');
      host = server.substring(0, lastColon);
      port = int.tryParse(server.substring(lastColon + 1)) ?? 0;
    } else if (uri.userInfo.isNotEmpty) {
      final decoded = _decodeBase64(uri.userInfo);
      final split = decoded.indexOf(':');
      _require(split > 0, 'SS 加密信息无效');
      method = decoded.substring(0, split);
      password = decoded.substring(split + 1);
    }
    _require(
      method.isNotEmpty && password.isNotEmpty && host.isNotEmpty && port > 0,
      'SS 链接信息不完整',
    );
    _require(!host.contains(' '), 'SS 服务器地址无效');

    final outbound = <String, dynamic>{
      'type': 'shadowsocks',
      'server': host,
      'server_port': port,
      'method': method,
      'password': password,
    };
    final query = _queryParameters(uri);
    final plugin = query['plugin'];
    if (plugin != null && plugin.isNotEmpty) {
      final parts = plugin.split(';');
      final name = parts.first;
      final opts = parts.skip(1).where((e) => e.contains('=')).join(';');
      if (name.contains('obfs')) {
        outbound['plugin'] = 'obfs-local';
        outbound['plugin_opts'] = opts;
      } else if (name.contains('v2ray')) {
        outbound['plugin'] = 'v2ray-plugin';
        outbound['plugin_opts'] = opts;
      } else {
        outbound['plugin'] = name;
        outbound['plugin_opts'] = opts;
      }
    }
    return outbound;
  }

  static Map<String, dynamic> _parseVmess(String link) {
    // The payload is Base64 and may contain upper-case letters and slashes, so
    // it must be read from the raw link instead of Uri (which normalizes host case).
    var payload = link.substring(link.indexOf('://') + 3);
    final fragment = payload.indexOf('#');
    if (fragment >= 0) payload = payload.substring(0, fragment);
    final query = payload.indexOf('?');
    if (query >= 0) payload = payload.substring(0, query);
    final decoded = _decodeBase64(_decodeComponent(payload));
    final Object? raw;
    try {
      raw = jsonDecode(decoded);
    } catch (_) {
      throw const ParseException('VMess 链接内容无效');
    }
    _require(raw is Map, 'VMess 链接内容无效');
    final data = Map<String, dynamic>.from(raw as Map);
    final server = data['add']?.toString() ?? '';
    final port = int.tryParse(data['port']?.toString() ?? '') ?? 0;
    final uuid = data['id']?.toString() ?? '';
    _require(server.isNotEmpty && port > 0 && uuid.isNotEmpty, 'VMess 必要字段缺失');

    final outbound = <String, dynamic>{
      'type': 'vmess',
      'server': server,
      'server_port': port,
      'uuid': uuid,
      'security': data['scy']?.toString().isNotEmpty == true
          ? data['scy']
          : 'auto',
      'alter_id': int.tryParse(data['aid']?.toString() ?? '0') ?? 0,
    };
    _applyV2RayTransport(
      outbound,
      network: data['net']?.toString() ?? 'tcp',
      headerType: data['type']?.toString(),
      host: data['host']?.toString(),
      path: data['path']?.toString(),
    );
    _applyTls(
      outbound,
      security: data['tls']?.toString() ?? '',
      sni: data['sni']?.toString(),
      alpn: data['alpn']?.toString(),
      fingerprint: data['fp']?.toString(),
      allowInsecure: false,
    );
    return outbound;
  }

  static Map<String, dynamic> _parseVless(Uri uri) {
    final uuid = uri.userInfo;
    final server = uri.host;
    final port = _port(uri);
    _require(uuid.isNotEmpty && server.isNotEmpty, 'VLESS 必要字段缺失');
    final q = _queryParameters(uri);
    final outbound = <String, dynamic>{
      'type': 'vless',
      'server': server,
      'server_port': port,
      'uuid': uuid,
      'packet_encoding': q['packetEncoding'] ?? q['packet_encoding'],
      'flow': q['flow'],
    }..removeWhere((key, value) => value == null || value == '');
    _applyV2RayTransport(
      outbound,
      network: q['type'] ?? 'tcp',
      headerType: q['headerType'],
      host: q['host'],
      path: q['path'],
      serviceName: q['serviceName'],
      earlyDataHeaderName: q['edName'],
      earlyDataLength: q['edLen'],
    );
    _applyTls(
      outbound,
      security: q['security'] ?? '',
      sni: q['sni'],
      alpn: q['alpn'],
      fingerprint: q['fp'],
      allowInsecure: q['allowInsecure'] == '1' || q['insecure'] == '1',
      publicKey: q['pbk'],
      shortId: q['sid'],
    );
    return outbound;
  }

  static Map<String, dynamic> _parseTrojan(Uri uri) {
    final password = uri.userInfo;
    final server = uri.host;
    final port = _port(uri);
    _require(password.isNotEmpty && server.isNotEmpty, 'Trojan 必要字段缺失');
    final q = _queryParameters(uri);
    final outbound = <String, dynamic>{
      'type': 'trojan',
      'server': server,
      'server_port': port,
      'password': password,
    };
    _applyV2RayTransport(
      outbound,
      network: q['type'] ?? 'tcp',
      headerType: q['headerType'],
      host: q['host'],
      path: q['path'],
      serviceName: q['serviceName'],
    );
    _applyTls(
      outbound,
      security: q['security'] ?? 'tls',
      sni: q['sni'] ?? q['peer'],
      alpn: q['alpn'],
      fingerprint: q['fp'],
      allowInsecure: q['allowInsecure'] == '1' || q['insecure'] == '1',
      publicKey: q['pbk'],
      shortId: q['sid'],
    );
    return outbound;
  }

  static Map<String, dynamic> _parseHysteria2(Uri uri) {
    final password = uri.userInfo;
    final server = uri.host;
    final port = _port(uri);
    _require(server.isNotEmpty, 'Hysteria2 必要字段缺失');
    final q = _queryParameters(uri);
    final outbound = <String, dynamic>{
      'type': 'hysteria2',
      'server': server,
      'server_port': port,
      'password': password,
    };
    final obfsPassword = q['obfs-password'] ?? q['obfsPassword'];
    if (q['obfs'] != null && q['obfs']!.isNotEmpty) {
      outbound['obfs'] = {'type': q['obfs'], 'password': obfsPassword ?? ''};
    }
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': q['sni'] ?? server,
      'insecure': q['insecure'] == '1' || q['allowInsecure'] == '1',
    };
    if (q['pinSHA256'] != null && q['pinSHA256']!.isNotEmpty) {
      tls['certificate_public_key_sha256'] = [q['pinSHA256']];
    }
    outbound['tls'] = tls;
    return outbound;
  }

  static Map<String, dynamic> _parseTuic(Uri uri) {
    final userInfo = _userInfo(uri);
    _require(userInfo.$1.isNotEmpty, 'TUIC 缺少 UUID');
    final q = _queryParameters(uri);
    final outbound = <String, dynamic>{
      'type': 'tuic',
      'server': uri.host,
      'server_port': _port(uri),
      'uuid': userInfo.$1,
      'password': userInfo.$2,
      'congestion_control': q['congestion_control'] ?? 'bbr',
      'udp_relay_mode': q['udp_relay_mode'] ?? 'native',
      'zero_rtt_handshake': q['zero_rtt_handshake'] == '1',
      'heartbeat': q['heartbeat'],
      'tls': {
        'enabled': true,
        'server_name': q['sni'] ?? uri.host,
        'alpn': q['alpn']?.split(',') ?? ['h3'],
        'insecure': q['allow_insecure'] == '1' || q['insecure'] == '1',
      },
    }..removeWhere((key, value) => value == null);
    return outbound;
  }

  static Map<String, dynamic> _parseAnyTls(Uri uri) {
    final q = _queryParameters(uri);
    return <String, dynamic>{
      'type': 'anytls',
      'server': uri.host,
      'server_port': _port(uri),
      'password': uri.userInfo,
      'tls': {
        'enabled': true,
        'server_name': q['sni'] ?? uri.host,
        'insecure': q['insecure'] == '1' || q['allowInsecure'] == '1',
      },
    };
  }

  static Map<String, dynamic> _parseSocks(Uri uri) {
    final userInfo = _userInfo(uri);
    return <String, dynamic>{
      'type': 'socks',
      'server': uri.host,
      'server_port': _port(uri),
      if (userInfo.$1.isNotEmpty) 'username': userInfo.$1,
      if (userInfo.$2.isNotEmpty) 'password': userInfo.$2,
      'version': '5',
    };
  }

  static Map<String, dynamic> _parseHttp(Uri uri) {
    final userInfo = _userInfo(uri);
    return <String, dynamic>{
      'type': 'http',
      'server': uri.host,
      'server_port': _port(uri),
      if (userInfo.$1.isNotEmpty) 'username': userInfo.$1,
      if (userInfo.$2.isNotEmpty) 'password': userInfo.$2,
      'tls': {'enabled': uri.scheme.toLowerCase() == 'https'},
    };
  }

  static void _applyV2RayTransport(
    Map<String, dynamic> outbound, {
    required String network,
    String? headerType,
    String? host,
    String? path,
    String? serviceName,
    String? earlyDataHeaderName,
    String? earlyDataLength,
  }) {
    final type = network.toLowerCase();
    switch (type) {
      case 'ws':
        outbound['transport'] = <String, dynamic>{
          'type': 'ws',
          if (path != null && path.isNotEmpty) 'path': path,
          if (host != null && host.isNotEmpty) 'headers': {'Host': host},
          if (earlyDataHeaderName != null && earlyDataHeaderName.isNotEmpty)
            'early_data_header_name': earlyDataHeaderName,
          if (earlyDataLength != null && int.tryParse(earlyDataLength) != null)
            'max_early_data': int.parse(earlyDataLength),
        };
      case 'grpc':
        outbound['transport'] = <String, dynamic>{
          'type': 'grpc',
          if ((serviceName ?? path)?.isNotEmpty == true)
            'service_name': serviceName ?? path,
          'idle_timeout': '15s',
          'ping_timeout': '15s',
        };
      case 'httpupgrade':
        outbound['transport'] = <String, dynamic>{
          'type': 'httpupgrade',
          if (path != null && path.isNotEmpty) 'path': path,
          if (host != null && host.isNotEmpty) 'host': host,
        };
      case 'http':
        outbound['transport'] = <String, dynamic>{
          'type': 'http',
          if (path != null && path.isNotEmpty) 'path': path,
          if (host != null && host.isNotEmpty) 'host': [host],
        };
      case 'quic':
        outbound['transport'] = <String, dynamic>{'type': 'quic'};
      case 'tcp':
        if (headerType == 'http') {
          outbound['transport'] = <String, dynamic>{
            'type': 'http',
            if (host != null && host.isNotEmpty) 'host': [host],
            if (path != null && path.isNotEmpty) 'path': path,
          };
        }
    }
  }

  static void _applyTls(
    Map<String, dynamic> outbound, {
    required String security,
    String? sni,
    String? alpn,
    String? fingerprint,
    bool allowInsecure = false,
    String? publicKey,
    String? shortId,
  }) {
    final value = security.toLowerCase();
    if (value != 'tls' && value != 'reality') return;
    final tls = <String, dynamic>{
      'enabled': true,
      if (sni != null && sni.isNotEmpty) 'server_name': sni,
      if (alpn != null && alpn.isNotEmpty) 'alpn': alpn.split(','),
      'insecure': allowInsecure,
    };
    if (fingerprint != null && fingerprint.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
    }
    if (value == 'reality') {
      if (publicKey == null || publicKey.isEmpty) {
        throw const ParseException('Reality 节点缺少 public key（pbk）');
      }
      tls['reality'] = <String, dynamic>{
        'enabled': true,
        'public_key': publicKey,
        if (shortId != null && shortId.isNotEmpty) 'short_id': shortId,
      };
    }
    outbound['tls'] = tls;
  }

  static String _decodeBase64(String input) {
    try {
      final normalized = base64Url.normalize(
        input.replaceAll(RegExp(r'\s'), ''),
      );
      final bytes = base64.decode(normalized);
      final text = utf8.decode(bytes);
      return text;
    } catch (_) {
      try {
        return utf8.decode(base64.decode(input));
      } catch (_) {
        throw const ParseException('Base64 内容无效');
      }
    }
  }

  static List<ProxyNode> _deduplicate(List<ProxyNode> nodes) {
    final seen = <String>{};
    return [
      for (final node in nodes)
        if (seen.add(fingerprintOf(node.outbound))) node,
    ];
  }

  static String fingerprintOf(Map<String, dynamic> outbound) =>
      _fingerprint(outbound);

  static String _fingerprint(Map<String, dynamic> outbound) {
    final ordered = _canonical(outbound);
    return sha256.convert(utf8.encode(jsonEncode(ordered))).toString();
  }

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((e) => e.toString()).toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
