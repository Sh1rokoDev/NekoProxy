import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../services/exit_info_service.dart';
import '../../state/app_controller.dart';

const _wideCardWidth = 540.0;
const _infoHeadingHeight = 28.0;
const _connectionActionSize = 52.0;
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
    final running = controller.running;
    final busy = controller.busy;
    final node = controller.currentNode;
    final exitInfo = controller.exitInfo;
    final source = _sourceName(controller, node);
    final statusText = busy
        ? '正在应用'
        : running
        ? '已连接'
        : '未连接';
    final connectedColor = theme.brightness == Brightness.dark
        ? const Color(0xFF7ADCA5)
        : const Color(0xFF11633F);
    final statusColor = busy
        ? scheme.primary
        : running
        ? connectedColor
        : scheme.onSurfaceVariant;
    final splitLabel = switch (controller.settings.splitMode) {
      SplitMode.rule => '规则分流',
      SplitMode.global => '全局代理',
      SplitMode.direct => '直连',
    };
    final modes = <Widget>[
      _ConnectionMode(
        icon: controller.settings.selectionMode == SelectionMode.auto
            ? Icons.auto_awesome_outlined
            : Icons.pan_tool_alt_rounded,
        label: controller.currentGroupLabel,
      ),
      const _ConnectionModeDot(),
      _ConnectionMode(icon: Icons.route_outlined, label: splitLabel),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(12) / 12;
        final wide =
            constraints.maxWidth >= _wideCardWidth * textScale.clamp(1, 2);
        final horizontalPadding = wide ? 20.0 : 14.0;
        final power = _ConnectionPowerButton(
          controller: controller,
          running: running,
          hasNodes: hasNodes,
          compact: !wide,
        );
        final meta = <Widget>[
          Wrap(
            spacing: 7,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ConnectionStatus(
                text: statusText,
                color: statusColor,
                active: running,
              ),
              _MetaSeparator(color: scheme.outlineVariant),
              if (running && TickerMode.valuesOf(context).enabled)
                ValueListenableBuilder<int>(
                  valueListenable: controller.liveTick,
                  builder: (context, _, _) =>
                      _ConnectionUptime(value: _uptime(controller)),
                )
              else
                _ConnectionUptime(value: running ? _uptime(controller) : '—'),
              _MetaSeparator(color: scheme.outlineVariant),
              ...modes,
            ],
          ),
          const SizedBox(height: 12),
        ];

        return AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.65),
            ),
            color: Color.alphaBlend(
              scheme.primary.withValues(
                alpha: theme.brightness == Brightness.light ? 0.02 : 0.035,
              ),
              scheme.surface,
            ),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              wide ? 15 : 13,
              horizontalPadding,
              wide ? 15 : 14,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Let the compact header use the space above the buttons.
                if (!wide) ...meta,
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (wide) ...meta,
                          _NodeDetails(
                            node: node,
                            hasNodes: hasNodes,
                            region: exitInfo?.region.trim() ?? '',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (running) ...[
                      _ConnectionRefreshButton(controller: controller),
                      const SizedBox(width: 8),
                    ],
                    power,
                  ],
                ),
                const SizedBox(height: 14),
                _ConnectionInfoStrip(
                  controller: controller,
                  info: exitInfo,
                  source: source,
                  wide: wide,
                ),
              ],
            ),
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
    required this.node,
    required this.hasNodes,
    required this.region,
  });

  final ProxyNode? node;
  final bool hasNodes;
  final String region;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final node = this.node;
    final address = Text(
      node == null
          ? (hasNodes ? '选择一个节点' : '导入订阅或节点')
          : '${node.server}:${node.port}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
        fontSize: 12,
        fontFamily: 'monospace',
        fontFamilyFallback: _fixedWidthFonts,
        letterSpacing: 0,
      ),
    );
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      alignment: Alignment.topLeft,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: SizedBox(
          key: ValueKey(node?.id ?? 'no-node'),
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                node?.name ?? (hasNodes ? '尚未选择节点' : '还没有节点'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontSize: 19,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 9),
              if (node != null && region.isNotEmpty)
                LayoutBuilder(
                  builder: (context, constraints) {
                    // Leave room for the address ellipsis even if the badge
                    // needs to wrap on a narrow card.
                    final reservedWidth = (constraints.maxWidth * 0.2).clamp(
                      0.0,
                      28.0,
                    );
                    return Row(
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth - reservedWidth,
                          ),
                          child: RegionBadge(
                            region: region,
                            semanticPrefix: '出口地区',
                          ),
                        ),
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: address,
                          ),
                        ),
                      ],
                    );
                  },
                )
              else
                address,
            ],
          ),
        ),
      ),
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
              size: 15,
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
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaSeparator extends StatelessWidget {
  const _MetaSeparator({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 11, color: color.withValues(alpha: 0.7));
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
        Icon(icon, size: 16, color: scheme.primary),
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

class _ConnectionModeDot extends StatelessWidget {
  const _ConnectionModeDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 3,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.outline,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _ConnectionPowerButton extends StatelessWidget {
  const _ConnectionPowerButton({
    required this.controller,
    required this.running,
    required this.hasNodes,
    required this.compact,
  });

  final AppController controller;
  final bool running;
  final bool hasNodes;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = controller.busy
        ? '请稍候'
        : running
        ? '断开连接'
        : hasNodes
        ? '连接'
        : '去导入';
    final background = running ? scheme.primary : scheme.primaryContainer;
    final foreground = running ? scheme.onPrimary : scheme.onPrimaryContainer;
    final icon = controller.busy
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
            color: foreground,
          );
    void onPressed() {
      if (!hasNodes && !running) {
        ShellScope.maybeOf(context)?.switchTab(1);
      } else {
        controller.toggleConnection();
      }
    }

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    Widget withShadow(Widget button) {
      if (!running || controller.busy) return button;
      return DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          shadows: [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.17),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: button,
      );
    }

    if (compact) {
      return withShadow(
        IconButton(
          key: const ValueKey('connection-power'),
          tooltip: label,
          onPressed: controller.busy ? null : onPressed,
          style: IconButton.styleFrom(
            fixedSize: const Size.square(_connectionActionSize),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: background,
            foregroundColor: foreground,
            shape: shape,
          ),
          icon: icon,
        ),
      );
    }

    return withShadow(
      FilledButton(
        key: const ValueKey('connection-power'),
        onPressed: controller.busy ? null : onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size(112, _connectionActionSize),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: background,
          foregroundColor: foreground,
          shape: shape,
          textStyle: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [icon, const SizedBox(width: 6), Text(label)],
        ),
      ),
    );
  }
}

class _ConnectionRefreshButton extends StatelessWidget {
  const _ConnectionRefreshButton({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final refreshing = controller.refreshingConnectionInfo;
    return IconButton.filledTonal(
      tooltip: '刷新出口、运营商和节点延迟',
      onPressed: controller.busy || refreshing
          ? null
          : controller.refreshConnectionInfo,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(_connectionActionSize),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: refreshing
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh_rounded, size: 20),
    );
  }
}

class _ConnectionInfoStrip extends StatelessWidget {
  const _ConnectionInfoStrip({
    required this.controller,
    required this.info,
    required this.source,
    required this.wide,
  });

  final AppController controller;
  final ExitInfo? info;
  final String? source;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dividerColor = scheme.outlineVariant.withValues(alpha: 0.65);
    final info = this.info;
    final provider = info?.provider.trim() ?? '';
    final node = controller.currentNode;
    final latency = node == null ? null : controller.latencies[node.id];
    final latencyError = node == null
        ? null
        : controller.latencyErrors[node.id];
    final exitError = controller.exitInfoError;
    final exitCell = _ConnectionDataCell(
      label: '出口 IP',
      padding: EdgeInsets.only(right: wide ? 12 : 8, bottom: 3),
      value: info != null
          ? SelectionArea(child: Text(info.ip, style: _infoAddressStyle))
          : Text(
              exitError ??
                  (controller.checkingExitInfo
                      ? '正在检测出口…'
                      : controller.running
                      ? '出口信息待检测'
                      : '连接后检测出口信息'),
              style: TextStyle(
                color: exitError != null
                    ? scheme.error
                    : controller.checkingExitInfo
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
            ),
    );
    final providerCell = _ConnectionDataCell(
      key: const ValueKey('connection-provider'),
      label: '运营商',
      padding: const EdgeInsets.only(left: 12, right: 8),
      value: Text(provider.isEmpty ? '未提供' : provider),
    );
    final latencyCell = _ConnectionDataCell(
      key: const ValueKey('connection-latency'),
      label: '节点延迟',
      padding: EdgeInsets.only(left: wide ? 12 : 0, right: 8),
      value: switch ((latency, latencyError)) {
        (final int delay, _) => _LatencyValue(latency: delay),
        (_, final String error) => Tooltip(
          message: error,
          child: const Text('测速失败'),
        ),
        _ => null,
      },
    );
    final sourceCell = _ConnectionDataCell(
      key: const ValueKey('connection-source'),
      label: '来源',
      padding: const EdgeInsets.only(left: 12),
      value: Text(source ?? '—', style: _infoAddressStyle),
    );

    Widget row(List<Widget> cells) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, cell) in cells.indexed) ...[
            if (index > 0) _StripDivider(color: dividerColor),
            Expanded(child: cell),
          ],
        ],
      ),
    );

    return Column(
      key: const ValueKey('connection-info-strip'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StripDivider(color: dividerColor, horizontal: true),
        const SizedBox(height: 8),
        if (wide)
          row([exitCell, providerCell, latencyCell, sourceCell])
        else ...[
          row([exitCell, providerCell]),
          const SizedBox(height: 5),
          _StripDivider(color: dividerColor, horizontal: true),
          const SizedBox(height: 5),
          row([latencyCell, sourceCell]),
        ],
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
    required this.padding,
    required this.value,
  });

  final String label;
  final EdgeInsets padding;
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
          fontWeight: FontWeight.w600,
        );
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: _infoHeadingHeight),
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 2),
          if (value case final value?)
            DefaultTextStyle(
              style: valueStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: value,
            ),
        ],
      ),
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

class _StripDivider extends StatelessWidget {
  const _StripDivider({required this.color, this.horizontal = false});

  final Color color;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: horizontal ? double.infinity : 1,
      height: horizontal ? 1 : null,
      color: color,
    );
  }
}
