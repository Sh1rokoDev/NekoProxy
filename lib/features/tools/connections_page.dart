import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key});

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppScope.read(context);
    if (controller.running) controller.refreshConnections();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: controller.liveTick,
      builder: (context, _, _) {
        final connections = controller.connections;
        return HeaderScaffold(
      title: const Text('当前连接'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: controller.running ? controller.refreshConnections : null,
          icon: const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: '关闭全部连接',
          onPressed: controller.running ? controller.clearConnections : null,
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
            ))
          : connections.isEmpty
              ? Padding(
              padding: EdgeInsets.only(top: headerInset),
              child: const Center(
                  child: EmptyState(
                    icon: Icons.hourglass_empty_rounded,
                    title: '暂无活动连接',
                    message: '浏览网页或使用应用后，这里会出现连接记录。',
                  ),
                ))
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(24, headerInset + 16, 24, 32),
                  itemCount: connections.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final connection = connections[index];
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              connection.network.toUpperCase().isEmpty ? 'TCP' : connection.network.toUpperCase(),
                              style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  connection.domain.isNotEmpty ? connection.domain : connection.destination,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${connection.source} → ${connection.destination} · ${connection.outbound}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                if (connection.rule.isNotEmpty)
                                  Text(
                                    '规则：${connection.rule}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.arrow_upward_rounded, size: 13, color: theme.colorScheme.primary),
                                  Text(formatBytes(connection.uploaded), style: theme.textTheme.labelSmall),
                                ],
                              ),
                              Row(
                                children: [
                                  Icon(Icons.arrow_downward_rounded, size: 13, color: theme.colorScheme.tertiary),
                                  Text(formatBytes(connection.downloaded), style: theme.textTheme.labelSmall),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
