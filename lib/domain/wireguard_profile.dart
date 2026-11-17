import 'dart:convert';
import 'dart:io';

enum OutboundMode { proxy, wireGuard, wireGuardProxy }

enum StandaloneOutbound { singBox, wireGuard }

class WireGuardGroup {
  const WireGuardGroup({required this.id, required this.name});

  static const legacy = WireGuardGroup(
    id: 'wireguard-default',
    name: 'WireGuard',
  );

  final String id;
  final String name;

  Map<String, String> toJson() => {'id': id, 'name': name};

  factory WireGuardGroup.fromJson(Map<String, dynamic> json) =>
      WireGuardGroup(id: json['id'] as String, name: json['name'] as String);
}

class WireGuardProfile {
  WireGuardProfile({
    required this.id,
    required this.name,
    required this.configuration,
    this.groupId = 'wireguard-default',
  });

  final String id;
  final String name;
  final String configuration;
  final String groupId;

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'configuration': configuration,
    'groupId': groupId,
  };

  factory WireGuardProfile.fromJson(Map<String, dynamic> json) =>
      WireGuardProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        configuration: json['configuration'] as String,
        groupId: json['groupId'] as String? ?? WireGuardGroup.legacy.id,
      );

  WireGuardConfig parse() => WireGuardConfig.parse(configuration);
}

class WireGuardConfig {
  const WireGuardConfig._(
    this.options,
    this.dns,
    this.searchDomains,
    this.peers,
  );

  final Map<String, Object> options;
  final List<String> dns;
  final List<String> searchDomains;
  final List<Map<String, Object>> peers;

  List<String> get allowedIps => [
    for (final peer in peers) ...(peer['allowed_ips'] as List<String>),
  ];

  bool get windowsProtection =>
      peers.length == 1 && allowedIps.any((cidr) => cidr.endsWith('/0'));

  String get firstEndpoint {
    final host = peers.first['address'] as String;
    final port = peers.first['port'];
    return host.contains(':') ? '[$host]:$port' : '$host:$port';
  }

  Map<String, Object> toEndpoint(String tag, {String? resolver}) => {
    'type': 'wireguard',
    'tag': tag,
    'system': false,
    ...options,
    'peers': peers,
    if (resolver != null) 'domain_resolver': {'server': resolver},
  };

  factory WireGuardConfig.parse(String source) {
    final sections = <Map<String, String>>[];
    Map<String, String>? current;
    for (final (index, raw) in const LineSplitter().convert(source).indexed) {
      final line = raw.split('#').first.replaceFirst('\uFEFF', '').trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[')) {
        final expected = sections.isEmpty ? '[interface]' : '[peer]';
        if (line.toLowerCase() != expected) {
          throw FormatException('第 ${index + 1} 行：需要 $expected');
        }
        current = {};
        sections.add(current);
        continue;
      }
      final equals = line.indexOf('=');
      if (equals <= 0 || current == null) {
        throw FormatException('第 ${index + 1} 行：无效的 WireGuard 配置项');
      }
      final field = line.substring(0, equals).trim().toLowerCase();
      final values = sections.length == 1 ? _interfaceFields : _peerFields;
      if (!values.contains(field)) {
        throw FormatException('第 ${index + 1} 行：不支持此 WireGuard 配置项');
      }
      final value = line.substring(equals + 1).trim();
      if (current.containsKey(field)) {
        if (const {'address', 'dns', 'allowedips'}.contains(field)) {
          current[field] = '${current[field]},$value';
          continue;
        }
        throw FormatException('第 ${index + 1} 行：重复的 WireGuard 配置项');
      }
      current[field] = value;
    }
    if (sections.length < 2) {
      throw const FormatException('配置至少需要一个 [Interface] 和一个 [Peer]');
    }
    final interface = sections.first;
    final dns = <String>[];
    final domains = <String>[];
    if (interface['dns'] case final value?) {
      for (final entry in value.split(',').map((item) => item.trim())) {
        if (_ip(entry) != null) {
          dns.add(entry);
        } else if (_hostname(entry)) {
          domains.add(entry);
        } else {
          throw const FormatException('WireGuard DNS 地址或搜索域无效');
        }
      }
    }
    return WireGuardConfig._(
      {
        'address': _prefixes(interface['address'], 'Address'),
        'private_key': _key(interface['privatekey'], 'PrivateKey'),
        if (interface['listenport'] case final value?)
          'listen_port': _number(value, 'ListenPort', 0, 65535),
        if (interface['mtu'] case final value?)
          'mtu': _number(value, 'MTU', 576, 65535),
      },
      dns,
      domains,
      [
        for (final peer in sections.skip(1))
          {
            ..._endpoint(peer['endpoint']),
            'public_key': _key(peer['publickey'], 'PublicKey'),
            'allowed_ips': _prefixes(peer['allowedips'], 'AllowedIPs'),
            if (peer['presharedkey'] case final value?)
              'pre_shared_key': _key(value, 'PresharedKey'),
            if (peer['persistentkeepalive'] case final value?)
              'persistent_keepalive_interval': value.toLowerCase() == 'off'
                  ? 0
                  : _number(value, 'PersistentKeepalive', 0, 65535),
          },
      ],
    );
  }

  static const _interfaceFields = {
    'address',
    'privatekey',
    'dns',
    'mtu',
    'listenport',
  };
  static const _peerFields = {
    'endpoint',
    'publickey',
    'allowedips',
    'presharedkey',
    'persistentkeepalive',
  };

  static InternetAddress? _ip(String value) =>
      value.contains('%') ? null : InternetAddress.tryParse(value);

  static bool _hostname(String value) =>
      value.length <= 253 &&
      value
          .replaceFirst(RegExp(r'\.$'), '')
          .split('.')
          .every(
            (label) =>
                RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$')
                    .hasMatch(label),
          );

  static List<String> _prefixes(String? value, String field) {
    final entries = value?.split(',').map((item) => item.trim()).toList() ?? [];
    if (entries.isEmpty) throw FormatException('缺少 $field');
    return [for (final entry in entries) _prefix(entry, field)];
  }

  static String _prefix(String entry, String field) {
    final parts = entry.split('/');
    final ip = _ip(parts.first);
    if (ip == null || parts.length > 2) throw FormatException('$field 含无效地址');
    final bits = ip.type == InternetAddressType.IPv4 ? 32 : 128;
    final prefix = parts.length == 1
        ? bits
        : _number(parts.last, field, 0, bits);
    if (field != 'AllowedIPs') return '${ip.address}/$prefix';
    final network = ip.rawAddress;
    for (var index = 0; index < network.length; index++) {
      final keep = (prefix - index * 8).clamp(0, 8);
      network[index] &= (255 << (8 - keep)) & 255;
    }
    return '${InternetAddress.fromRawAddress(network).address}/$prefix';
  }

  static int _number(String? value, String field, int min, int max) {
    final number = value == null || !RegExp(r'^\d+$').hasMatch(value)
        ? null
        : int.tryParse(value);
    if (number == null || number < min || number > max) {
      throw FormatException('$field 必须在 $min–$max 之间');
    }
    return number;
  }

  static String _key(String? value, String field) {
    if (value != null && RegExp(r'^[A-Za-z0-9+/]{43}=$').hasMatch(value)) {
      if (base64Decode(value).length == 32) return value;
    }
    throw FormatException('$field 必须是 32 字节的 Base64 密钥');
  }

  static Map<String, Object> _endpoint(String? value) {
    final match = RegExp(r'^(?:\[([^\]]+)\]|([^:\s]+)):(\d+)$')
        .firstMatch(value ?? '');
    final host = match?.group(1) ?? match?.group(2);
    if (host == null || (_ip(host) == null && !_hostname(host))) {
      throw const FormatException('Endpoint 必须是地址:端口，IPv6 地址使用方括号');
    }
    return {
      'address': host,
      'port': _number(match?.group(3), 'Endpoint 端口', 1, 65535),
    };
  }
}
