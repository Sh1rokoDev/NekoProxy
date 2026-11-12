import 'models.dart';

List<String> splitFilterKeywords(String raw) => raw
    .split(RegExp(r'[\n,，]'))
    .map((item) => item.trim().toLowerCase())
    .where((item) => item.isNotEmpty)
    .toList();

bool nodeMatchesFilter(
  ProxyNode node, {
  required String includeFilter,
  required String excludeFilter,
}) {
  final include = splitFilterKeywords(includeFilter);
  final exclude = splitFilterKeywords(excludeFilter);
  final haystack = '${node.name} ${node.server} ${node.protocol}'.toLowerCase();
  if (include.isNotEmpty && !include.any(haystack.contains)) return false;
  if (exclude.any(haystack.contains)) return false;
  return true;
}

List<ProxyNode> applyNodeView({
  required Iterable<ProxyNode> nodes,
  String includeFilter = '',
  String excludeFilter = '',
  NodeSortMode sortMode = NodeSortMode.manual,
  bool sortDescending = false,
  Map<String, int> latencies = const {},
}) {
  final visible = [
    for (final node in nodes)
      if (nodeMatchesFilter(
        node,
        includeFilter: includeFilter,
        excludeFilter: excludeFilter,
      ))
        node,
  ];
  return sortNodeList(
    visible,
    mode: sortMode,
    descending: sortDescending,
    latencies: latencies,
  );
}

List<ProxyNode> sortNodeList(
  List<ProxyNode> nodes, {
  required NodeSortMode mode,
  required bool descending,
  Map<String, int> latencies = const {},
}) {
  final indexed = [
    for (var i = 0; i < nodes.length; i++) (index: i, node: nodes[i]),
  ];
  indexed.sort((a, b) {
    int primary;
    switch (mode) {
      case NodeSortMode.manual:
        primary = a.index.compareTo(b.index);
        return descending ? -primary : primary;
      case NodeSortMode.name:
        primary = a.node.name.toLowerCase().compareTo(
          b.node.name.toLowerCase(),
        );
      case NodeSortMode.protocol:
        primary = a.node.protocol.toLowerCase().compareTo(
          b.node.protocol.toLowerCase(),
        );
        if (primary == 0) {
          primary = a.node.name.toLowerCase().compareTo(
            b.node.name.toLowerCase(),
          );
        }
      case NodeSortMode.latency:
        final left = latencies[a.node.id];
        final right = latencies[b.node.id];
        if (left == null && right == null) {
          primary = a.index.compareTo(b.index);
          return primary;
        }
        if (left == null) return 1;
        if (right == null) return -1;
        primary = left.compareTo(right);
      case NodeSortMode.favorite:
        primary = (b.node.favorite ? 1 : 0).compareTo(a.node.favorite ? 1 : 0);
    }
    if (primary != 0) return descending ? -primary : primary;
    return a.index.compareTo(b.index);
  });
  return [for (final entry in indexed) entry.node];
}
