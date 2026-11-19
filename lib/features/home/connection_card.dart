import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/proxy_latency_builder.dart';
import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../services/exit_info_service.dart';
import '../../state/app_controller.dart';

const _wideCardWidth = 540.0;

const _connectionActionSize = 48.0;
const _fixedWidthFonts = ['Consolas'];

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({
    super.key,
    required this.controller,
    required this.hasNodes,
  });

  final AppController controller;
  final bool hasNodes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = controller.running || controller.applyingTunTakeover;
    final busy = controller.busy || controller.applyingTunTakeover;
    final profile = controller.activeWireGuard;
    final onlyWireGuard = controller.outboundMode == OutboundMode.wireGuard;
    final node = onlyWireGuard ? null : controller.currentNode;
    String? endpoint;
    if (profile != null) {
      try {
        endpoint = profile.parse().firstEndpoint;
      } on FormatException {
        endpoint = 'WireGuard 配置无效';
      }
    }
    final exitInfo = controller.exitInfo;
    final chain = controller.chainProxyEnabled;
    final sideBySide =
        chain && MediaQuery.orientationOf(context) == Orientation.landscape;
    final wgSource = controller.snapshot.wireGuardGroups
        .where((group) => group.id == profile?.groupId)
        .firstOrNull
        ?.name;
    final region = exitInfo?.region.trim() ?? '';
    final statusText = busy
        ? '正在应用'
        : running
        ? (profile != null && exitInfo == null ? '核心已启动' : '已连接')
        : '未连接';
    final connectedColor = theme.brightness == Brightness.dark
        ? const Color(0xFF7ADCA5)
        : const Color(0xFF11633F);
    final statusColor = busy
        ? scheme.primary
        : running
        ? connectedColor
        : scheme.onSurfaceVariant;
    final mode = _ConnectionMode(
      icon: onlyWireGuard || chain
          ? Icons.route_outlined
          : controller.settings.selectionMode == SelectionMode.auto
          ? Icons.bolt_outlined
          : Icons.touch_app_outlined,
      label: onlyWireGuard
          ? (controller.usesTun ? '按 AllowedIPs 路由' : '仅接管代理流量')
          : chain
          ? '链式代理 · ${controller.currentGroupLabel}'
          : controller.currentGroupLabel,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = (MediaQuery.textScalerOf(context).scale(12) / 12)
            .clamp(1, 2);
        const wideInset = 18.0;
        const dividerWidth = 25.0;
        final sideWidth = (constraints.maxWidth * .31).clamp(
          256.0 * textScale,
          360.0 * textScale,
        );
        final wideDetailsWidth =
            constraints.maxWidth - sideWidth - 2 * wideInset - 2;
        final wide =
            constraints.maxWidth >= _wideCardWidth * textScale &&
            (!sideBySide ||
                wideDetailsWidth >= _wideCardWidth * textScale + dividerWidth);
        const compactInset = 14.0;
        final inset = wide ? wideInset : compactInset;
        final detailsWidth = wide
            ? wideDetailsWidth
            : constraints.maxWidth - 2 * compactInset - 2;
        final nodeWidth = sideBySide
            ? (detailsWidth - dividerWidth) / 2
            : detailsWidth;
        final nodes = [
          if (chain || onlyWireGuard)
            _NodeDetails(
              maxRegionWidth: nodeWidth * .65,
              type: 'WireGuard',
              source: wgSource,
              level: chain ? '第一级' : null,
              name: profile?.name ?? '尚未选择 WireGuard 节点',
              address: endpoint ?? '选择一个 WireGuard 节点',
              region: chain ? controller.wireGuardEndpointRegion ?? '' : region,
              regionSemanticPrefix: chain ? '对端地区' : '出口地区',
            ),
          if (!onlyWireGuard)
            _NodeDetails(
              maxRegionWidth: nodeWidth * .65,
              type: 'SingBox',
              source: _sourceName(controller, node),
              level: chain ? '第二级' : null,
              name: node?.name ?? (hasNodes ? '尚未选择节点' : '还没有节点'),
              address: node == null
                  ? (hasNodes ? '选择一个节点' : '导入订阅或节点')
                  : '${node.server}:${node.port}',
              region: region,
            ),
        ];
        final details = Padding(
          padding: EdgeInsets.all(inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 4,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: .09),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: _ConnectionStatus(
                          text: statusText,
                          color: statusColor,
                          active: running,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (running && TickerMode.valuesOf(context).enabled)
                        ValueListenableBuilder<int>(
                          valueListenable: controller.liveTick,
                          builder: (context, _, _) =>
                              _ConnectionUptime(value: _uptime(controller)),
                        )
                      else
                        _ConnectionUptime(
                          value: running ? _uptime(controller) : '—',
                        ),
                    ],
                  ),
                  mode,
                ],
              ),
              const SizedBox(height: 12),
              if (sideBySide)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, item) in nodes.indexed) ...[
                        if (index > 0)
                          const VerticalDivider(
                            width: dividerWidth,
                            thickness: 1,
                          ),
                        Expanded(child: item),
                      ],
                    ],
                  ),
                )
              else
                for (final (index, item) in nodes.indexed) ...[
                  if (index > 0) const Divider(height: 17, thickness: 1),
                  item,
                ],
            ],
          ),
        );
        final diagnostics = ColoredBox(
          color: scheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ConnectionInfoStrip(controller: controller, info: exitInfo),
                if (wide) const Spacer(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (running) ...[
                      Expanded(
                        child: _ConnectionRefreshButton(controller: controller),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: _ConnectionPowerButton(
                        controller: controller,
                        running: running,
                        hasNodes: controller.canConnect,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.65),
            ),
            color: scheme.surfaceContainerLow,
          ),
          child: wide
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: details),
                      SizedBox(width: sideWidth, child: diagnostics),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [details, diagnostics],
                ),
        );
      },
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

class _NodeDetails extends StatelessWidget {
  const _NodeDetails({
    required this.maxRegionWidth,
    required this.type,
    required this.source,
    required this.level,
    required this.name,
    required this.address,
    required this.region,
    this.regionSemanticPrefix = '出口地区',
  });
  final double maxRegionWidth;
  final String type, name, address, region;
  final String regionSemanticPrefix;
  final String? source, level;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (level case final level?)
              RegionBadge(region: level, semanticPrefix: '代理级别'),
            Text(
              type,
              style: labelStyle?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (source case final source?)
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  Text('来源', style: labelStyle),
                  Flexible(
                    child: Tooltip(
                      key: const ValueKey('connection-source'),
                      message: source,
                      child: Text(
                        source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontSize: 20,
            height: 1.25,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (region.isNotEmpty) ...[
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxRegionWidth),
                child: RegionBadge(
                  region: region,
                  semanticPrefix: regionSemanticPrefix,
                  shortLabel: region,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle?.merge(_infoAddressStyle),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({
    required this.text,
    required this.color,
    required this.active,
  });

  final String text;
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: active
                ? Border.all(color: color.withValues(alpha: 0.42))
                : null,
          ),
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ),
        const SizedBox(width: 4),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Text(
            text,
            key: ValueKey(text),
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _ConnectionUptime extends StatelessWidget {
  const _ConnectionUptime({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      label: '运行时长 $value',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.schedule_rounded,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionMode extends StatelessWidget {
  const _ConnectionMode({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _ConnectionPowerButton extends StatelessWidget {
  const _ConnectionPowerButton({
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
    final busy = controller.busy || controller.applyingTunTakeover;
    final label = controller.applyingTunTakeover
        ? '断开'
        : busy
        ? '请稍候'
        : running
        ? '断开'
        : hasNodes
        ? '连接'
        : '导入节点';
    final foreground = scheme.onPrimary;
    final icon = busy
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
          )
        : Icon(
            hasNodes || running
                ? Icons.power_settings_new_rounded
                : Icons.file_download_outlined,
            size: 20,
          );
    void onPressed() {
      if (!hasNodes && !running) {
        ShellScope.maybeOf(context)?.switchTab(1);
      } else {
        controller.toggleConnection();
      }
    }

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return FilledButton(
      key: const ValueKey('connection-power'),
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(112, _connectionActionSize),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: scheme.primary,
        foregroundColor: foreground,
        shape: shape,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionRefreshButton extends StatelessWidget {
  const _ConnectionRefreshButton({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final refreshing = controller.refreshingConnectionInfo;
    return Tooltip(
      message: '刷新出口、运营商和节点延迟',
      child: FilledButton.tonalIcon(
        onPressed: controller.busy || refreshing
            ? null
            : controller.refreshConnectionInfo,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, _connectionActionSize),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurfaceVariant,
        ),
        icon: refreshing
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh_rounded, size: 20),
        label: const Text(
          '刷新',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _ConnectionInfoStrip extends StatelessWidget {
  const _ConnectionInfoStrip({required this.controller, required this.info});

  final AppController controller;
  final ExitInfo? info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final info = this.info;
    final provider = info?.provider.trim() ?? '';
    final onlyWireGuard = controller.outboundMode == OutboundMode.wireGuard;
    final node = onlyWireGuard ? null : controller.currentNode;
    final wireGuardLatency = onlyWireGuard ? controller.wireGuardLatency : null;
    final exitError = controller.exitInfoError;
    final exitCell = _ConnectionDataCell(
      label: '出口 IP',
      value: switch ((info, exitError)) {
        (final ExitInfo info, _) => SelectionArea(
          child: Text(info.ip, style: _infoAddressStyle),
        ),
        (_, final String error) => Text(
          error,
          style: TextStyle(color: scheme.error),
        ),
        _ when controller.checkingExitInfo => Text(
          '正在检测出口…',
          style: TextStyle(color: scheme.primary),
        ),
        _ => const Text('未知'),
      },
    );
    final providerCell = _ConnectionDataCell(
      key: const ValueKey('connection-provider'),
      label: '运营商',
      value: Text(provider.isEmpty ? '未知' : provider),
    );
    final latencyCell = ProxyLatencyBuilder(
      controller: controller,
      nodeId: node?.id,
      builder: (context) {
        final latency = node == null
            ? wireGuardLatency?.delay
            : controller.latencies[node.id];
        final latencyError = node == null
            ? wireGuardLatency?.error
            : controller.latencyErrors[node.id];
        return _ConnectionDataCell(
          key: const ValueKey('connection-latency'),
          label: '节点延迟',
          value: switch ((latency, latencyError)) {
            (final int delay, _) => _LatencyValue(latency: delay),
            (_, final String error) => Tooltip(
              message: error,
              child: const Text('测速失败'),
            ),
            _ => const Text('未知'),
          },
        );
      },
    );
    return Column(
      key: const ValueKey('connection-info-strip'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        exitCell,
        const SizedBox(height: 8),
        providerCell,
        const SizedBox(height: 8),
        latencyCell,
      ],
    );
  }
}

const _infoAddressStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: _fixedWidthFonts,
  letterSpacing: 0,
);

class _ConnectionDataCell extends StatelessWidget {
  const _ConnectionDataCell({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final Widget? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final valueStyle = (theme.textTheme.bodySmall ?? const TextStyle())
        .copyWith(
          color: scheme.onSurface,
          fontSize: 13,
          height: 1.5,
          fontWeight: FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    return Row(
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: DefaultTextStyle(
              style: valueStyle,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              child: value ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}

class _LatencyValue extends StatelessWidget {
  const _LatencyValue({required this.latency});

  final int latency;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = latency < 150
        ? const Color(0xFF1B9E63)
        : latency < 350
        ? const Color(0xFFC68A00)
        : scheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Match the visible edge of the label, accounting for its glyph inset.
        Padding(
          padding: const EdgeInsets.only(left: 1),
          child: _LatencyBars(color: color),
        ),
        const SizedBox(width: 4),
        Flexible(child: Text(formatLatency(latency))),
      ],
    );
  }
}

class _LatencyBars extends StatelessWidget {
  const _LatencyBars({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final height in const [3.0, 5.0, 7.0, 9.0]) ...[
          Container(
            width: 2,
            height: height,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          if (height != 9.0) const SizedBox(width: 2),
        ],
      ],
    );
  }
}
