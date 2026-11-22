import 'models.dart';

final _filterSeparator = RegExp(r'[\n,，]');

List<String> splitFilterKeywords(String raw) => raw
    .split(_filterSeparator)
    .map((item) => item.trim().toLowerCase())
    .where((item) => item.isNotEmpty)
    .toList();

bool _matches(ProxyNode node, List<String> include, List<String> exclude) {
  if (include.isEmpty && exclude.isEmpty) return true;
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
  final include = splitFilterKeywords(includeFilter);
  final exclude = splitFilterKeywords(excludeFilter);
  final visible = include.isEmpty && exclude.isEmpty
      ? nodes.toList()
      : nodes.where((node) => _matches(node, include, exclude)).toList();
  if (sortMode == NodeSortMode.manual && !sortDescending) return visible;
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
  if (mode == NodeSortMode.manual) {
    return descending ? nodes.reversed.toList() : List.of(nodes);
  }
  if (mode == NodeSortMode.latency && latencies.isEmpty) {
    return List.of(nodes);
  }
  final sortByName = mode == NodeSortMode.name || mode == NodeSortMode.protocol;
  final indexed = [
    for (var i = 0; i < nodes.length; i++)
      (
        index: i,
        node: nodes[i],
        name: sortByName ? nodes[i].name.toLowerCase() : '',
        protocol: mode == NodeSortMode.protocol
            ? nodes[i].protocol.toLowerCase()
            : '',
        delay: mode == NodeSortMode.latency ? latencies[nodes[i].id] : null,
      ),
  ];
  indexed.sort((a, b) {
    int primary;
    switch (mode) {
      case NodeSortMode.manual:
        return 0; // Handled before building the sort keys.
      case NodeSortMode.name:
        primary = a.name.compareTo(b.name);
      case NodeSortMode.protocol:
        primary = a.protocol.compareTo(b.protocol);
        if (primary == 0) {
          primary = a.name.compareTo(b.name);
        }
      case NodeSortMode.latency:
        final left = a.delay;
        final right = b.delay;
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
