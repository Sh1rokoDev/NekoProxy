import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/dialogs.dart';
import '../../app/widgets.dart';
import '../../domain/config_compiler.dart';
import '../../runtime/runtime_client.dart';

class ConnectionListCard extends StatelessWidget {
  const ConnectionListCard({
    super.key,
    required this.connection,
    required this.onClose,
    this.nodeName,
    this.ruleName,
  });

  final RuntimeConnection connection;
  final VoidCallback onClose;
  final String? nodeName;
  final String? ruleName;

  static const _blockedOutboundTags = {
    'block',
    'reject',
    'reject-drop',
    'reject-reply',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final network = connection.network.trim().toUpperCase();
    final outbound = connection.outbound.trim();
    final name = ruleName?.trim();
    final rule = name != null && name.isNotEmpty
        ? name
        : connection.ruleIndex == null && connection.rule.trim().isEmpty
        ? '未匹配'
        : null;
    final requestAddress = connection.domain.isNotEmpty
        ? connection.domain
        : connection.destination;
    final resolvedNodeName = nodeName?.trim();
    return LayoutBuilder(
      builder: (context, constraints) {
        final rightWidth = math.min(
          164.0,
          math.max(120.0, constraints.maxWidth * 0.28),
        );
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.65),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _ConnectionBadge(
                          label: network.isEmpty ? 'TCP' : network,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          flex: 2,
                          child: _ConnectionBadge(
                            label: _outboundLabel(outbound, resolvedNodeName),
                          ),
                        ),
                        if (rule != null) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            flex: 3,
                            child: _ConnectionBadge(label: rule, muted: true),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      requestAddress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _nodeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: rightWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Flexible(
                          child: _ConnectionStat(
                            icon: Icons.arrow_upward_rounded,
                            value: formatBytes(connection.uploaded),
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: _ConnectionStat(
                            icon: Icons.arrow_downward_rounded,
                            value: formatBytes(connection.downloaded),
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        HeaderIconButton(
                          tooltip: '查看详情',
                          onPressed: () => _showDetails(context, rule),
                          icon: Icons.info_outline_rounded,
                        ),
                        const SizedBox(width: 8),
                        HeaderIconButton(
                          tooltip: '关闭连接',
                          onPressed: onClose,
                          icon: Icons.link_off_rounded,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String get _nodeLabel {
    final name = nodeName?.trim();
    return name == null || name.isEmpty ? 'DIRECT' : name;
  }

  void _showDetails(BuildContext context, String? rule) {
    final fields = <String, String>{
      if (connection.domain.isNotEmpty) '域名': connection.domain,
      '来源地址': connection.source,
      '目标地址': connection.destination,
      '协议': connection.network.toUpperCase(),
      '节点': _nodeLabel,
      '规则': ?rule,
      '上传量': formatBytes(connection.uploaded),
      '下载量': formatBytes(connection.downloaded),
      if (connection.createdAt > 0)
        '建立时间': formatDate(
          DateTime.fromMillisecondsSinceEpoch(connection.createdAt),
        ),
    };
    showAppDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        size: AppDialogSize.standard,
        title: const Text('连接详情'),
        content: SelectionArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, field) in fields.entries.indexed) ...[
                if (index > 0) const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    spacing: 12,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          field.key,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(flex: 7, child: Text(field.value)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  String _outboundLabel(String outbound, String? resolvedNodeName) {
    final normalized = outbound.toLowerCase();
    if (normalized == ConfigCompiler.directTag) return '直连';
    if (_blockedOutboundTags.contains(normalized)) return '阻断';
    if (resolvedNodeName != null && resolvedNodeName.isNotEmpty) return '代理';
    return outbound.isEmpty ? '未知' : outbound;
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.label, this.muted = false});

  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: muted
            ? scheme.surfaceContainerHighest
            : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: muted ? scheme.onSurfaceVariant : scheme.onSecondaryContainer,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _ConnectionStat extends StatelessWidget {
  const _ConnectionStat({
    required this.icon,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: theme.textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}
