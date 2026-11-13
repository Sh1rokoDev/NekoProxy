import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../runtime/runtime_client.dart';
import '../../state/app_controller.dart';
import 'connection_list_card.dart';

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key});

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  AppController? _controller;
  VoidCallback? _stopWatching;
  bool _searchOpen = false;
  String _query = '';

  void _toggleSearch() => setState(() {
    _searchOpen = !_searchOpen;
    _query = '';
  });

  bool _matchesSearch(AppController controller, RuntimeConnection connection) {
    return [
      connection.domain,
      connection.source,
      connection.destination,
      connection.outbound,
      connection.network,
      controller.nodeNameForOutboundTag(connection.outbound),
      controller.nameForMatchedRule(connection.ruleIndex),
    ].any((value) => value?.toLowerCase().contains(_query) ?? false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppScope.of(context);
    final visible = TickerMode.valuesOf(context).enabled;
    if (!identical(controller, _controller) || !visible) {
      _stopWatching?.call();
      _stopWatching = null;
      _controller = controller;
    }
    if (visible) {
      _stopWatching ??= controller.watchConnections();
    }
  }

  @override
  void dispose() {
    _stopWatching?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return ValueListenableBuilder<List<RuntimeConnection>>(
      valueListenable: controller.connectionUpdates,
      builder: (context, connections, _) {
        final visibleConnections = _query.isEmpty
            ? connections
            : connections
                  .where((item) => _matchesSearch(controller, item))
                  .toList();
        return HeaderScaffold(
          title: _searchOpen
              ? TextField(
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: (value) => setState(() {
                    _query = value.trim().toLowerCase();
                  }),
                  decoration: const InputDecoration(
                    hintText: '搜索连接',
                    isDense: true,
                  ),
                )
              : const Text('当前连接'),
          actions: [
            IconButton(
              tooltip: _searchOpen ? '关闭搜索' : '搜索连接',
              onPressed: _searchOpen || controller.running
                  ? _toggleSearch
                  : null,
              icon: Icon(
                _searchOpen ? Icons.close_rounded : Icons.search_rounded,
              ),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: controller.running
                  ? controller.refreshConnections
                  : null,
              icon: const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              tooltip: '关闭全部连接',
              onPressed: controller.running
                  ? controller.clearConnections
                  : null,
              icon: const Icon(Icons.link_off_rounded),
            ),
            const SizedBox(width: 8),
          ],
          fadeTail: 16,
          body: (headerInset) => !controller.running
              ? Padding(
                  padding: EdgeInsets.only(top: headerInset),
                  child: const Center(
                    child: EmptyState(
                      icon: Icons.power_off_rounded,
                      title: '核心未运行',
                      message: '连接后可以在此查看每个连接的来源、目标与出口。',
                    ),
                  ),
                )
              : visibleConnections.isEmpty
              ? Padding(
                  padding: EdgeInsets.only(top: headerInset),
                  child: Center(
                    child: EmptyState(
                      icon: _query.isEmpty
                          ? Icons.hourglass_empty_rounded
                          : Icons.search_off_rounded,
                      title: _query.isEmpty ? '暂无活动连接' : '没有匹配的连接',
                      message: _query.isEmpty
                          ? '浏览网页或使用应用后，这里会出现连接记录。'
                          : '试试其他搜索词。',
                    ),
                  ),
                )
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(24, headerInset + 16, 24, 32),
                  itemCount: visibleConnections.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final connection = visibleConnections[index];
                    return ConnectionListCard(
                      key: ValueKey(connection.id),
                      connection: connection,
                      onClose: () => controller.closeConnection(connection.id),
                      ruleName: controller.nameForMatchedRule(
                        connection.ruleIndex,
                      ),
                      nodeName: controller.nodeNameForOutboundTag(
                        connection.outbound,
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
