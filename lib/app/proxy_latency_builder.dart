import 'package:flutter/widgets.dart';

import '../state/app_controller.dart';

/// Rebuilds a node's latency display as its result arrives during a bulk test.
class ProxyLatencyBuilder extends StatefulWidget {
  const ProxyLatencyBuilder({
    super.key,
    required this.controller,
    required this.nodeId,
    required this.builder,
  });

  final AppController controller;
  final String? nodeId;
  final WidgetBuilder builder;

  @override
  State<ProxyLatencyBuilder> createState() => _ProxyLatencyBuilderState();
}

class _ProxyLatencyBuilderState extends State<ProxyLatencyBuilder> {
  VoidCallback? _stopWatching;

  @override
  void initState() {
    super.initState();
    _watchLatency();
  }

  @override
  void didUpdateWidget(ProxyLatencyBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.nodeId != widget.nodeId) {
      _watchLatency();
    }
  }

  void _watchLatency() {
    _stopWatching?.call();
    final nodeId = widget.nodeId;
    _stopWatching = nodeId == null
        ? null
        : widget.controller.watchProxyLatency(nodeId, () => setState(() {}));
  }

  @override
  void dispose() {
    _stopWatching?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
