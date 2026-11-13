import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';
import '../rules/split_mode_switch.dart';

class HomeSplitModeCard extends StatelessWidget {
  const HomeSplitModeCard({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final inline = constraints.maxWidth >= 420 * textScale;
        final control = SplitModeSwitch(
          controller: controller,
          width: inline ? 216 : double.infinity,
        );
        return SectionCard(
          title: '规则模式',
          icon: Icons.route_outlined,
          trailing: inline ? control : null,
          padding: inline ? EdgeInsets.zero : const EdgeInsets.all(20),
          child: inline ? const SizedBox.shrink() : control,
        );
      },
    );
  }
}

class HomeTrafficCard extends StatelessWidget {
  const HomeTrafficCard({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final up = [for (final sample in controller.samples) sample.up];
    final down = [for (final sample in controller.samples) sample.down];
    Widget metric(String label, Color color, List<double> values, int total) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(width: 16, height: 3, color: color),
                const SizedBox(width: 6),
                Text(label),
              ],
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                formatSpeed(values.lastOrNull ?? 0),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '本次 ${formatBytes(total)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '峰值 ${formatSpeed(values.fold<double>(0, math.max))}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return SectionCard(
      title: '实时流量',
      icon: Icons.show_chart_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              metric('上传', scheme.primary, up, controller.traffic.uploaded),
              const SizedBox(width: 12),
              metric(
                '下载',
                scheme.tertiary,
                down,
                controller.traffic.downloaded,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Semantics(
            label: '上传和下载速率趋势，使用相同刻度',
            child: TrafficSparkline(up: up, down: down, height: 140),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                controller.samples.isEmpty
                    ? '等待流量数据'
                    : '${DateTime.now().difference(controller.samples.first.time).inSeconds} 秒前',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text('现在', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}

class HomeSubscriptionCard extends StatefulWidget {
  const HomeSubscriptionCard({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeSubscriptionCard> createState() => _HomeSubscriptionCardState();
}

class _HomeSubscriptionCardState extends State<HomeSubscriptionCard> {
  bool _updating = false;

  Future<void> _refresh(
    AppController controller,
    Subscription subscription,
  ) async {
    setState(() => _updating = true);
    try {
      await controller.updateSubscription(subscription.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('订阅更新失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final subscription = controller.currentSubscription;
    return SectionCard(
      title: '订阅用量',
      icon: Icons.inventory_2_outlined,
      trailing: IconButton(
        tooltip: '更新订阅',
        onPressed: subscription == null || _updating
            ? null
            : () => _refresh(controller, subscription),
        icon: _updating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh_rounded),
      ),
      child: subscription == null
          ? _SubscriptionEmptyState(controller: controller)
          : _SubscriptionOverview(subscription: subscription),
    );
  }
}

class _SubscriptionEmptyState extends StatelessWidget {
  const _SubscriptionEmptyState({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final hasSubscriptions = controller.snapshot.subscriptions.any(
      (subscription) => subscription.isUrlSubscription,
    );
    return Text(
      hasSubscriptions ? '当前节点不属于订阅，请在节点页选择订阅节点' : '导入订阅后查看用量、到期和更新信息',
    );
  }
}

class _SubscriptionOverview extends StatelessWidget {
  const _SubscriptionOverview({required this.subscription});

  final Subscription subscription;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final upload = subscription.uploadBytes;
    final download = subscription.downloadBytes;
    final total = subscription.totalBytes;
    final hasUsage = upload != null || download != null || total != null;
    final used = (upload ?? 0) + (download ?? 0);
    final hasTraffic = total != null && total > 0;
    final progress = total != null && total > 0
        ? (used / total).clamp(0.0, 1.0).toDouble()
        : null;
    final remaining = total != null && total > 0
        ? math.max(0, total - used)
        : null;
    final progressColor = progress != null && progress >= 0.9
        ? scheme.error
        : scheme.primary;
    final expiry = subscription.expireAt;
    final updated = subscription.lastUpdated;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.rss_feed_rounded,
                size: 20,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subscription.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '当前订阅 · ${subscription.nodes.length} 个节点',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (hasUsage) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  hasTraffic
                      ? '已用 ${formatBytes(used)} / ${formatBytes(total)}'
                      : '已用 ${formatBytes(used)}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (progress != null)
                Text(
                  '${(progress * 100).toStringAsFixed(progress < 0.1 ? 1 : 0)}%',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: progressColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              borderRadius: BorderRadius.circular(4),
              color: progressColor,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ] else if (total == null) ...[
            const SizedBox(height: 4),
            Text(
              '订阅未提供总流量额度',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _UsageMetric(label: '上传', value: formatBytes(upload ?? 0)),
                _UsageMetric(label: '下载', value: formatBytes(download ?? 0)),
                if (remaining != null)
                  _UsageMetric(label: '剩余', value: formatBytes(remaining)),
              ],
            ),
          ),
        ] else
          Text(
            '订阅未提供用量数据',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: 16),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
        if (expiry != null)
          _SubscriptionDetailRow(
            icon: Icons.event_outlined,
            label: '到期时间',
            value: _expiryText(expiry),
            color: expiry.isAfter(DateTime.now()) ? null : scheme.error,
          ),
        _SubscriptionDetailRow(
          icon: Icons.autorenew_rounded,
          label: '自动更新',
          value: _autoUpdateText(
            enabled: subscription.autoUpdate,
            intervalMinutes: subscription.effectiveUpdateIntervalMinutes,
          ),
        ),
        if (updated != null)
          _SubscriptionDetailRow(
            icon: Icons.update_rounded,
            label: '上次更新',
            value: formatDate(updated),
          ),
        if (subscription.lastError case final error?)
          _SubscriptionDetailRow(
            icon: Icons.error_outline_rounded,
            label: '同步状态',
            value: error,
            color: scheme.error,
          ),
      ],
    );
  }

  String _expiryText(DateTime expiry) {
    final now = DateTime.now();
    final date = DateFormat('yyyy.MM.dd').format(expiry.toLocal());
    if (!expiry.isAfter(now)) return '$date · 已到期';
    final days = expiry.difference(now).inDays;
    if (days <= 0) return '$date · 今天到期';
    return '$date · 剩余 $days 天';
  }

  String _autoUpdateText({
    required bool enabled,
    required int intervalMinutes,
  }) {
    if (!enabled) return '已关闭';
    if (intervalMinutes % 60 == 0) {
      return '每 ${intervalMinutes ~/ 60} 小时';
    }
    return '每 $intervalMinutes 分钟';
  }
}

class _UsageMetric extends StatelessWidget {
  const _UsageMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionDetailRow extends StatelessWidget {
  const _SubscriptionDetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color ?? scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color ?? scheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HomeActivityCard extends StatelessWidget {
  const HomeActivityCard({super.key, required this.controller});
  static const _maxVisibleActivities = 3;

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '最近活动',
      icon: Icons.history_rounded,
      child: controller.homeActivities.isEmpty
          ? const Text('本次启动暂无活动')
          : Column(
              children: [
                for (final activity in controller.homeActivities.take(
                  _maxVisibleActivities,
                ))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          activity.failed
                              ? Icons.error_outline_rounded
                              : Icons.check_circle_outline_rounded,
                          size: 18,
                          color: activity.failed
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(activity.message)),
                        const SizedBox(width: 10),
                        Text(
                          DateFormat('HH:mm').format(activity.time),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
