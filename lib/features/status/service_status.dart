import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app/app_scope.dart';
import '../../app/widgets.dart';
import '../../services/connectivity_service.dart';
import '../../state/app_controller.dart';

class ServiceStatusCard extends StatelessWidget {
  const ServiceStatusCard({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final featured = connectivityServices
        .where((service) => service.featured)
        .toList();
    final results = [
      for (final service in featured) controller.serviceChecks[service.id],
    ];
    final allResults = [
      for (final service in connectivityServices)
        controller.serviceChecks[service.id],
    ];
    final checking = connectivityServices.any(
      (service) => controller.isServiceChecking(service.id),
    );
    final failed = allResults
        .where((result) => result?.isFailed ?? false)
        .length;
    final available = allResults
        .where((result) => result?.isAvailable ?? false)
        .length;
    final checked = failed + available;
    final badge = checking
        ? '检测中'
        : checked == 0
        ? '待检测'
        : failed > 0
        ? '$failed 项异常'
        : checked == connectivityServices.length
        ? '全部可用'
        : '$available 项可用';
    final badgeBackground = checking
        ? scheme.secondaryContainer
        : checked == 0
        ? scheme.surfaceContainerHighest
        : failed > 0
        ? scheme.errorContainer
        : const Color(0xFF1B9E63).withValues(alpha: 0.14);
    final badgeForeground = checking
        ? scheme.onSecondaryContainer
        : checked == 0
        ? scheme.onSurfaceVariant
        : failed > 0
        ? scheme.onErrorContainer
        : theme.brightness == Brightness.dark
        ? const Color(0xFF7ADCA5)
        : const Color(0xFF11633F);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const ServiceStatusPage())),
      child: SectionCard(
        title: '服务状态',
        icon: Icons.shield_outlined,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Badge(
              text: badge,
              background: badgeBackground,
              foreground: badgeForeground,
            ),
            IconButton(
              tooltip: '检测全部',
              visualDensity: VisualDensity.compact,
              onPressed: controller.serviceCheckBusy
                  ? null
                  : () => controller.checkServiceStatus(),
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: controller.serviceCheckBusy
                    ? const SizedBox(
                        key: ValueKey('checking'),
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.refresh_rounded,
                        key: ValueKey('refresh'),
                        size: 20,
                      ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _ServiceTile(service: featured[0], result: results[0]),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ServiceTile(service: featured[1], result: results[1]),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _ServiceTile(service: featured[2], result: results[2]),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ServiceTile(service: featured[3], result: results[3]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ServiceStatusPage extends StatelessWidget {
  const ServiceStatusPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final results = [
      for (final service in connectivityServices)
        controller.serviceChecks[service.id],
    ];
    final failed = results.where((result) => result?.isFailed ?? false).length;
    final available = results
        .where((result) => result?.isAvailable ?? false)
        .length;
    final checked = failed + available;
    final busy = controller.serviceCheckBusy;
    ServiceCheckResult? last;
    for (final result in results) {
      if (result?.checkedAt == null) continue;
      if (last == null || result!.checkedAt!.isAfter(last.checkedAt!)) {
        last = result;
      }
    }
    final viaTun = busy
        ? controller.checksViaTun
        : (last?.viaTun ?? controller.checksViaTun);
    final viaProxy = busy
        ? controller.checksViaProxy
        : (last?.viaProxy ?? controller.checksViaProxy);
    final routeLabel = viaTun ? '经 VPN' : (viaProxy ? '经代理' : '直连');
    final title = busy
        ? '正在检测…'
        : checked == 0
        ? '尚未检测'
        : '$available / ${connectivityServices.length} 可用';
    final subtitle = busy
        ? '$routeLabel · 已检测 $checked / ${connectivityServices.length}'
        : checked == 0
        ? '$routeLabel · 共 ${connectivityServices.length} 项'
        : '$routeLabel · 已检测 $checked 项';
    return Scaffold(
      appBar: AppBar(title: const Text('服务状态')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: Text(
                                title,
                                key: ValueKey(title),
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            const SizedBox(height: 2),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: Text(
                                subtitle,
                                key: ValueKey(subtitle),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.tonalIcon(
                        onPressed: busy
                            ? null
                            : () => controller.checkServiceStatus(),
                        icon: busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(busy ? '检测中' : '全部检测'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SectionCard(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      children: [
                        for (
                          var index = 0;
                          index < connectivityServices.length;
                          index++
                        ) ...[
                          _ServiceRow(
                            service: connectivityServices[index],
                            result: controller
                                .serviceChecks[connectivityServices[index].id],
                            busy: busy,
                            onCheck: () => controller.checkServiceStatus(
                              id: connectivityServices[index].id,
                            ),
                          ),
                          if (index != connectivityServices.length - 1)
                            Divider(
                              height: 1,
                              indent: 66,
                              endIndent: 16,
                              color: scheme.outlineVariant.withValues(
                                alpha: 0.4,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({required this.service, required this.result});

  final ConnectivityService service;
  final ServiceCheckResult? result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = _statusColor(theme, result);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          ServiceLogo(service: service, size: 32),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: Text(
                          _statusText(result),
                          key: ValueKey(_statusText(result)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: color,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.service,
    required this.result,
    required this.busy,
    required this.onCheck,
  });

  final ConnectivityService service;
  final ServiceCheckResult? result;
  final bool busy;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final checking = result?.isChecking ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 9, 6, 9),
      child: Row(
        children: [
          ServiceLogo(service: service, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        service.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusPill(result: result),
                  ],
                ),
                const SizedBox(height: 3),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    _metaText(service, result),
                    key: ValueKey(_metaText(service, result)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '重新检测',
            visualDensity: VisualDensity.compact,
            onPressed: busy || checking ? null : onCheck,
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: checking
                  ? const SizedBox(
                      key: ValueKey('row-checking'),
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(
                      Icons.refresh_rounded,
                      key: ValueKey('row-refresh'),
                      size: 19,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.result});

  final ServiceCheckResult? result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (
      String label,
      Color background,
      Color foreground,
    ) = switch (result?.status) {
      ServiceCheckStatus.available => (
        '可用',
        const Color(0xFF1B9E63).withValues(alpha: 0.14),
        theme.brightness == Brightness.dark
            ? const Color(0xFF7ADCA5)
            : const Color(0xFF11633F),
      ),
      ServiceCheckStatus.failed => (
        '检测失败',
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      ServiceCheckStatus.checking => (
        '检测中',
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      _ => ('待检测', scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(7),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Text(
            label,
            key: ValueKey(label),
            style: theme.textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Text(
            text,
            key: ValueKey(text),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class ServiceLogo extends StatelessWidget {
  const ServiceLogo({super.key, required this.service, this.size = 40});

  final ConnectivityService service;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: SvgPicture.asset(
        'assets/icons/services/${service.id}.svg',
        fit: BoxFit.contain,
        semanticsLabel: service.name,
      ),
    );
  }
}

Color _statusColor(ThemeData theme, ServiceCheckResult? result) =>
    switch (result?.status) {
      ServiceCheckStatus.available =>
        theme.brightness == Brightness.dark
            ? const Color(0xFF7ADCA5)
            : const Color(0xFF1B9E63),
      ServiceCheckStatus.failed => theme.colorScheme.error,
      ServiceCheckStatus.checking => theme.colorScheme.primary,
      _ => theme.colorScheme.onSurfaceVariant,
    };

String _statusText(ServiceCheckResult? result) {
  if (result == null || result.isPending) return '待检测';
  return switch (result.status) {
    ServiceCheckStatus.available =>
      result.latencyMs == null ? '可用' : formatLatency(result.latencyMs),
    ServiceCheckStatus.failed => '检测失败',
    ServiceCheckStatus.checking => '检测中…',
    ServiceCheckStatus.pending => '待检测',
  };
}

String _metaText(ConnectivityService service, ServiceCheckResult? result) {
  if (result == null || result.isPending) return '—';
  if (result.isChecking) return '正在连接 ${service.host}';
  final time = _formatTime(result.checkedAt);
  if (result.isFailed) {
    return [result.error ?? '检测失败', time].join(' · ');
  }
  final address = result.address ?? service.host;
  final latency = result.latencyMs == null
      ? '—'
      : formatLatency(result.latencyMs);
  return [address, latency, time].join(' · ');
}

String _formatTime(DateTime? time) {
  if (time == null) return '—';
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}
