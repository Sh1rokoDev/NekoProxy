import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/widgets.dart';
import '../../domain/config_compiler.dart';
import '../../runtime/runtime_client.dart';

class ConnectionListCard extends StatelessWidget {
  const ConnectionListCard({
    super.key,
    required this.connection,
    this.nodeName,
  });

  final RuntimeConnection connection;
  final String? nodeName;

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
    final rule = connection.rule.trim();
    final requestAddress = connection.domain.isNotEmpty
        ? connection.domain
        : connection.destination;
    final resolvedNodeName = nodeName?.trim();

    return LayoutBuilder(
      builder: (context, constraints) {
        final rightWidth = math.min(
          205.0,
          math.max(88.0, constraints.maxWidth * 0.34),
        );
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
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
                        const SizedBox(width: 6),
                        Flexible(
                          flex: 3,
                          child: _ConnectionBadge(
                            label: rule.isEmpty ? '未匹配' : rule,
                            muted: true,
                          ),
                        ),
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
                      '${connection.source} → ${connection.destination}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: rightWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _ConnectionStat(
                      icon: Icons.arrow_upward_rounded,
                      value: formatBytes(connection.uploaded),
                      color: scheme.primary,
                    ),
                    _ConnectionStat(
                      icon: Icons.arrow_downward_rounded,
                      value: formatBytes(connection.downloaded),
                      color: scheme.tertiary,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      resolvedNodeName == null || resolvedNodeName.isEmpty
                          ? '—'
                          : resolvedNodeName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: muted
            ? scheme.surfaceContainerHighest
            : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: muted ? scheme.onSurfaceVariant : scheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
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
      mainAxisAlignment: MainAxisAlignment.end,
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
