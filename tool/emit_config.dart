import 'dart:io';

import 'package:nekoproxy/domain/config_compiler.dart';
import 'package:nekoproxy/domain/models.dart';

void main(List<String> args) {
  final output = args.isNotEmpty ? args.first : 'build/validation/config.json';
  final node = ProxyNode(
    id: 'local-1',
    tag: 'node-local-1',
    name: 'Local test',
    outbound: {
      'type': 'shadowsocks',
      'server': '127.0.0.1',
      'server_port': 8388,
      'method': 'aes-128-gcm',
      'password': 'test-only',
    },
  );
  final snapshot = AppSnapshot(
    settings: AppSettings(manualNodeId: node.id),
    subscriptions: [
      Subscription(id: 'local', name: 'Test', nodes: [node]),
    ],
  );
  final compiled = ConfigCompiler.compile(
    snapshot,
    target: args.contains('android')
        ? CompileTarget.android
        : (Platform.isWindows ? CompileTarget.windows : CompileTarget.android),
    cachePath: '${Directory.current.path}/build/validation/cache.db',
    logPath: '${Directory.current.path}/build/validation/core.log',
  );
  final file = File(output);
  file.parent.createSync(recursive: true);
  final ruleDirectory = Directory(ConfigCompiler.ruleSetDirectory(file.absolute.path));
  ruleDirectory.createSync(recursive: true);
  for (final name in ['geosite-cn.srs', 'geoip-cn.srs']) {
    File('assets/rules/$name').copySync('${ruleDirectory.path}/$name');
  }
  file.writeAsStringSync(compiled.encoded);
  stdout.writeln(file.path);
}
