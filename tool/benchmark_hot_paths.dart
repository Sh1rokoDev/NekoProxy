import 'dart:io';
import 'dart:convert';

import 'package:nekoproxy/domain/config_compiler.dart';
import 'package:nekoproxy/domain/models.dart';
import 'package:nekoproxy/domain/node_view.dart';
import 'package:nekoproxy/domain/profile_parser.dart';

void main(List<String> arguments) {
  final count = arguments.isEmpty ? 5000 : int.parse(arguments.single);
  final links = List.generate(
    count,
    (i) => 'trojan://sample@node-$i.example:443#Region-${count - i}',
  ).join('\n');
  final nodes = ProfileParser.parse(links, subscriptionId: 'sample').nodes;
  final snapshot = AppSnapshot(
    settings: AppSettings(),
    subscriptions: [Subscription(id: 'sample', name: 'Sample', nodes: nodes)],
  );
  final saved = snapshot.encode();
  stdout.writeln('$count synthetic nodes');
  _measure('default node list', () => applyNodeView(nodes: nodes).length);
  _measure(
    'filtered and sorted node list',
    () => applyNodeView(
      nodes: nodes,
      includeFilter: 'region, hk, jp',
      excludeFilter: 'unused, expired',
      sortMode: NodeSortMode.protocol,
    ).length,
  );
  _measure(
    'config compilation',
    () => ConfigCompiler.compile(
      snapshot,
      target: CompileTarget.windows,
      cachePath: 'runtime/cache.db',
    ).encoded.length,
  );
  _measure(
    'subscription parsing',
    () => ProfileParser.parse(links).nodes.length,
  );
  _measure(
    'local state decoding',
    () =>
        AppSnapshot.fromJson(jsonDecode(saved) as Map<String, dynamic>)
            .allNodes
            .length,
  );
}

void _measure(String name, int Function() run) {
  var checksum = 0;
  for (var i = 0; i < 6; i++) {
    checksum += run();
  }
  final samples = List.generate(15, (_) {
    final timer = Stopwatch()..start();
    checksum += run();
    return timer.elapsedMicroseconds;
  })..sort();
  final median = samples[samples.length ~/ 2] / 1000;
  stdout.writeln('$name: ${median.toStringAsFixed(2)} ms (median, $checksum)');
}
