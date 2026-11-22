class PolicyViolation {
  const PolicyViolation(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => '$path: $message';
}

/// Enforces the product's hard boundary: sing-box only, real-IP DNS only,
/// and no Clash/Mihomo interoperability.
class ConfigPolicy {
  ConfigPolicy._();

  static List<PolicyViolation> validate(Map<String, dynamic> config) {
    final violations = <PolicyViolation>[];
    _walk(config, '', violations);
    _validateDns(config, violations);
    _validateExperimental(config, violations);
    return violations;
  }

  static void _walk(
    Object? node,
    String path,
    List<PolicyViolation> violations,
  ) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString();
        final childPath = path.isEmpty ? key : '$path.$key';
        if (key == 'clash_api') {
          violations.add(PolicyViolation(childPath, '不允许启用 Clash API'));
        }
        if (key == 'clash_mode') {
          violations.add(PolicyViolation(childPath, '不允许使用 Clash 模式'));
        }
        if (key == 'fakeip') {
          violations.add(PolicyViolation(childPath, '不允许配置 FakeIP'));
        }
        _walk(entry.value, childPath, violations);
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        _walk(node[i], '$path[$i]', violations);
      }
    }
  }

  static void _validateDns(
    Map<String, dynamic> config,
    List<PolicyViolation> violations,
  ) {
    final dns = config['dns'];
    if (dns is! Map) return;
    final servers = dns['servers'];
    if (servers is! List) return;
    for (var i = 0; i < servers.length; i++) {
      final server = servers[i];
      if (server is! Map) continue;
      final type = server['type'];
      if (type == 'fakeip') {
        violations.add(
          PolicyViolation('dns.servers[$i].type', '不允许 FakeIP DNS 服务器'),
        );
      }
      if (type == null && server['address'] != null) {
        violations.add(
          PolicyViolation('dns.servers[$i]', '旧版 DNS 服务器格式不受支持，请使用带 type 的新格式'),
        );
      }
    }
  }

  static void _validateExperimental(
    Map<String, dynamic> config,
    List<PolicyViolation> violations,
  ) {
    final services = config['services'];
    if (services is List) {
      for (var i = 0; i < services.length; i++) {
        final service = services[i];
        if (service is Map && service['type'] == 'api') {
          violations.add(
            PolicyViolation('services[$i].type', '不允许开放核心管理 API；应用使用自己的受控本地通道'),
          );
        }
      }
    }
  }
}
