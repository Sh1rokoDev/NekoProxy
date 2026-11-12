import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';
import '../status/service_status.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final hasNodes = controller.hasNodes;
    return PageFrame(
      title: '首页',
      scrollable: false,
      actions: _NetworkTakeoverActions(controller: controller),
      child: Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 860;
            final mainColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ConnectionCard(controller: controller, hasNodes: hasNodes),
                const SizedBox(height: 16),
                _TrafficCards(controller: controller),
              ],
            );
            final sideColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [ServiceStatusCard(controller: controller)],
            );
            if (wide) {
              return SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 7, child: mainColumn),
                    const SizedBox(width: 18),
                    Expanded(flex: 5, child: sideColumn),
                  ],
                ),
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [mainColumn, const SizedBox(height: 16), sideColumn],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.controller, required this.hasNodes});

  final AppController controller;
  final bool hasNodes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = controller.running;
    final node = controller.currentNode;
    final statusText = controller.busy
        ? '正在应用'
        : running
        ? '已连接'
        : '未连接';
    final green = theme.brightness == Brightness.dark
        ? const Color(0xFF7ADCA5)
        : const Color(0xFF11633F);
    final statusColor = controller.busy
        ? scheme.primary
        : running
        ? green
        : scheme.onSurfaceVariant;
    final statusBackground = controller.busy
        ? scheme.secondaryContainer
        : running
        ? const Color(0xFF1B9E63).withValues(alpha: 0.14)
        : scheme.surfaceContainerHighest;
    final source = _sourceName(controller, node);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.surfaceContainerLow,
            running
                ? scheme.primaryContainer.withValues(alpha: 0.5)
                : scheme.surfaceContainerLow,
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -70,
            top: -90,
            child: _Orb(
              size: 230,
              color: scheme.primary.withValues(alpha: running ? 0.12 : 0.07),
            ),
          ),
          Positioned(
            right: 40,
            bottom: -80,
            child: _Orb(
              size: 160,
              color: scheme.tertiary.withValues(alpha: 0.07),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: statusBackground,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StatusDot(
                            active: running,
                            color: running ? const Color(0xFF1B9E63) : null,
                            size: 7,
                          ),
                          const SizedBox(width: 7),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            child: Text(
                              statusText,
                              key: ValueKey(statusText),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: statusColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (running) ...[
                      const SizedBox(width: 10),
                      Text(
                        '运行 ${_uptime(controller)}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnimatedSize(
                            duration: const Duration(milliseconds: 220),
                            alignment: Alignment.topLeft,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 240),
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0, 0.08),
                                        end: Offset.zero,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  ),
                              child: Column(
                                key: ValueKey(node?.id ?? 'no-node'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    node?.name ??
                                        (hasNodes ? '尚未选择节点' : '还没有节点'),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.headlineMedium
                                        ?.copyWith(fontSize: 30),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    node == null
                                        ? (hasNodes ? '选择一个节点' : '导入订阅或节点')
                                        : '${node.server}:${node.port}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _InfoChip(
                                icon:
                                    controller.settings.selectionMode ==
                                        SelectionMode.auto
                                    ? Icons.auto_awesome_rounded
                                    : Icons.pan_tool_alt_rounded,
                                label: controller.currentGroupLabel,
                              ),
                              _InfoChip(
                                icon: Icons.alt_route_rounded,
                                label: switch (controller.settings.splitMode) {
                                  SplitMode.rule => '规则分流',
                                  SplitMode.global => '全局代理',
                                  SplitMode.direct => '直连',
                                },
                              ),
                              if (controller.supportsSystemProxy &&
                                  controller.settings.systemProxyEnabled)
                                const _InfoChip(
                                  icon: Icons.language_rounded,
                                  label: '系统代理',
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    _PowerButton(
                      controller: controller,
                      running: running,
                      hasNodes: hasNodes,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Divider(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _MetaItem(
                        label: '运行时长',
                        value: running ? _uptime(controller) : '—',
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      flex: 3,
                      child: _MetaItem(label: '来源', value: source ?? '—'),
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

  String? _sourceName(AppController controller, ProxyNode? node) {
    if (node == null) return null;
    if (node.subscriptionId == null) return '手动添加';
    for (final subscription in controller.snapshot.subscriptions) {
      if (subscription.id == node.subscriptionId) return subscription.name;
    }
    return '手动添加';
  }

  String _uptime(AppController controller) {
    final started = controller.connectedAt;
    if (started == null) return '—';
    return formatDuration(DateTime.now().difference(started));
  }
}

class _Orb extends StatelessWidget {
  const _Orb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _PowerButton extends StatelessWidget {
  const _PowerButton({
    required this.controller,
    required this.running,
    required this.hasNodes,
  });

  final AppController controller;
  final bool running;
  final bool hasNodes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = running ? scheme.primary : scheme.primaryContainer;
    final foreground = running ? scheme.onPrimary : scheme.onPrimaryContainer;
    return Column(
      children: [
        Semantics(
          button: true,
          label: running ? '断开连接' : '连接',
          child: Material(
            color: background,
            shape: const CircleBorder(),
            elevation: running ? 2 : 0,
            animationDuration: const Duration(milliseconds: 250),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: controller.busy
                  ? null
                  : () {
                      if (!hasNodes && !running) {
                        ShellScope.maybeOf(context)?.switchTab(1);
                      } else {
                        controller.toggleConnection();
                      }
                    },
              child: SizedBox(
                width: 78,
                height: 78,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: animation,
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: controller.busy
                      ? Padding(
                          key: const ValueKey('busy'),
                          padding: const EdgeInsets.all(26),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: foreground,
                          ),
                        )
                      : Icon(
                          running
                              ? Icons.power_settings_new_rounded
                              : Icons.bolt_rounded,
                          key: ValueKey(running),
                          size: 34,
                          color: foreground,
                        ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          controller.busy
              ? '请稍候'
              : running
              ? '断开'
              : (hasNodes ? '连接' : '去导入'),
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _TrafficCards extends StatelessWidget {
  const _TrafficCards({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final traffic = controller.traffic;
    final up = [for (final sample in controller.samples) sample.up];
    final down = [for (final sample in controller.samples) sample.down];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _TrafficMetricCard(
            icon: Icons.arrow_upward_rounded,
            label: '上传',
            color: scheme.primary,
            value: up.isEmpty ? 0 : up.last,
            total: traffic.uploaded,
            peak: up.isEmpty ? 0 : up.reduce(math.max),
            samples: up,
            isUpload: true,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _TrafficMetricCard(
            icon: Icons.arrow_downward_rounded,
            label: '下载',
            color: scheme.tertiary,
            value: down.isEmpty ? 0 : down.last,
            total: traffic.downloaded,
            peak: down.isEmpty ? 0 : down.reduce(math.max),
            samples: down,
            isUpload: false,
          ),
        ),
      ],
    );
  }
}

class _TrafficMetricCard extends StatelessWidget {
  const _TrafficMetricCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.value,
    required this.total,
    required this.peak,
    required this.samples,
    required this.isUpload,
  });

  final IconData icon;
  final String label;
  final Color color;
  final double value;
  final int total;
  final double peak;
  final List<double> samples;
  final bool isUpload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    '峰值 ${formatSpeed(peak)}',
                    maxLines: 1,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatSpeed(value),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontSize: 27,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '累计 ${formatBytes(total)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TrafficSparkline(
            up: isUpload ? samples : const [],
            down: isUpload ? const [] : samples,
            height: 48,
            showGrid: false,
          ),
        ],
      ),
    );
  }
}

class _NetworkTakeoverActions extends StatelessWidget {
  const _NetworkTakeoverActions({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = !controller.busy;
    final items = <Widget>[
      if (controller.isAndroid)
        _CompactSwitch(
          icon: Icons.vpn_key_rounded,
          label: 'VPN',
          value: controller.running,
          enabled: enabled,
          onChanged: (value) =>
              value ? controller.connect() : controller.disconnect(),
        )
      else ...[
        _CompactSwitch(
          icon: Icons.lan_outlined,
          label: 'TUN',
          value: controller.settings.tunEnabled,
          enabled: enabled,
          onChanged: (value) => controller.setTun(value),
        ),
        if (controller.supportsSystemProxy)
          _CompactSwitch(
            icon: Icons.language_rounded,
            label: '系统代理',
            value: controller.settings.systemProxyEnabled,
            enabled: enabled,
            onChanged: (value) => controller.setSystemProxy(value),
          ),
      ],
    ];
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < items.length; index++) ...[
            if (index > 0)
              Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            items[index],
          ],
        ],
      ),
    );
  }
}

class _CompactSwitch extends StatelessWidget {
  const _CompactSwitch({
    required this.icon,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    void toggle() {
      if (enabled) onChanged(!value);
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: toggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(7, 2, 3, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: enabled
                  ? (value ? scheme.primary : scheme.onSurfaceVariant)
                  : scheme.outline,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: enabled ? scheme.onSurfaceVariant : scheme.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 1),
            SizedBox(
              width: 42,
              height: 30,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Switch(
                  value: value,
                  onChanged: enabled ? onChanged : null,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
