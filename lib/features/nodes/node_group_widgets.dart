import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../app/widgets.dart' show formatLatency;

class NodeGroupSurface extends StatefulWidget {
  const NodeGroupSurface({
    super.key,
    required this.active,
    required this.builder,
    this.continuesBelow = false,
  });

  final bool active;
  final bool continuesBelow;
  final Widget Function(
    BuildContext context,
    bool hovered,
    ValueChanged<bool> onPressedChanged,
  )
  builder;

  @override
  State<NodeGroupSurface> createState() => _NodeGroupSurfaceState();
}

class _NodeGroupSurfaceState extends State<NodeGroupSurface>
    with SingleTickerProviderStateMixin {
  late final _pressOpacity = AnimationController(
    vsync: this,
    reverseDuration: const Duration(milliseconds: 200),
  );
  bool _hovered = false;

  @override
  void dispose() {
    _pressOpacity.dispose();
    super.dispose();
  }

  void _updatePressHighlight(bool pressed) {
    if (pressed) {
      // Even a quick tap that ends before the next frame leaves a visible fade.
      _pressOpacity.value = 1;
    } else {
      _pressOpacity.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = scheme.surfaceContainerLow;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        // Border.lerp cannot animate between a closed card and an open edge.
        key: ValueKey(widget.continuesBelow),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        clipBehavior: Clip.antiAlias,
        decoration: nodeGroupDecoration(
          scheme,
          active: widget.active,
          last: !widget.continuesBelow,
          background: _hovered
              ? Color.alphaBlend(theme.hoverColor, background)
              : background,
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: FadeTransition(
                  opacity: _pressOpacity,
                  child: ColoredBox(color: theme.highlightColor),
                ),
              ),
            ),
            widget.builder(context, _hovered, _updatePressHighlight),
          ],
        ),
      ),
    );
  }
}

BoxDecoration nodeGroupDecoration(
  ColorScheme scheme, {
  required bool active,
  bool first = true,
  bool last = true,
  Color? background,
}) {
  final side = BorderSide(
    width: active ? 1.4 : 1,
    color: active
        ? scheme.primary.withValues(alpha: 0.65)
        : scheme.outlineVariant.withValues(alpha: 0.35),
  );
  const corner = Radius.circular(22);
  return BoxDecoration(
    color: background ?? scheme.surfaceContainerLow,
    borderRadius: BorderRadius.vertical(
      top: first ? corner : Radius.zero,
      bottom: last ? corner : Radius.zero,
    ),
    border: Border(
      top: first ? side : BorderSide.none,
      left: side,
      right: side,
      bottom: last ? side : BorderSide.none,
    ),
  );
}

ButtonStyle nodeGroupActionStyle(
  ColorScheme scheme, {
  bool background = true,
  double size = 36,
}) {
  return IconButton.styleFrom(
    backgroundColor: background
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.55)
        : Colors.transparent,
    foregroundColor: scheme.onSurfaceVariant,
    disabledBackgroundColor: background
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.3)
        : Colors.transparent,
    disabledForegroundColor: scheme.onSurfaceVariant.withValues(alpha: 0.45),
    fixedSize: Size(size, size),
    minimumSize: Size(size, size),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  );
}

class NodeGroupHeader extends StatelessWidget {
  const NodeGroupHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.titleTrailing,
    required this.expanded,
    required this.hovered,
    required this.onToggle,
    required this.onHighlightChanged,
    required this.actions,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? titleTrailing;
  final bool expanded;
  final bool hovered;
  final VoidCallback onToggle;
  final ValueChanged<bool> onHighlightChanged;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final actionStyle = nodeGroupActionStyle(
      scheme,
      background: false,
      size: 32,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onToggle,
        onHighlightChanged: onHighlightChanged,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 19, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (titleTrailing case final trailing?) ...[
                          const SizedBox(width: 6),
                          trailing,
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 2),
              ...actions,
              const SizedBox(width: 4),
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: hovered
                      ? actionStyle.overlayColor?.resolve({WidgetState.hovered})
                      : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NodeGroupBody extends StatelessWidget {
  const NodeGroupBody({super.key, required this.expanded, required this.child});

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: expanded
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
                child,
              ],
            )
          : const SizedBox(width: double.infinity),
    );
  }
}

class NodeGrid extends StatelessWidget {
  const NodeGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  static const tileHeight = 74.0;
  static const spacing = 8.0;

  static int columnsForWidth(double width) => width >= 940
      ? 4
      : width >= 620
      ? 3
      : 2;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = columnsForWidth(constraints.maxWidth);
      return GridView.builder(
        shrinkWrap: true,
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
        itemCount: itemCount,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: tileHeight,
          crossAxisSpacing: spacing,
          mainAxisSpacing: spacing,
        ),
        itemBuilder: itemBuilder,
      );
    },
  );
}

class NodeTile extends StatelessWidget {
  const NodeTile({
    super.key,
    required this.name,
    required this.protocol,
    this.address,
    required this.current,
    required this.onSelect,
    required this.footer,
  });

  final String name;
  final String protocol;
  final String? address;
  final bool current;
  final VoidCallback? onSelect;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onSelect,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 4),
          decoration: BoxDecoration(
            color: current
                ? scheme.primaryContainer.withValues(alpha: 0.5)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: current
                  ? scheme.primary.withValues(alpha: 0.6)
                  : scheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: current
                          ? scheme.primary
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      _protocolBadge(protocol),
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        color: current
                            ? scheme.onPrimary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (address case final endpoint?) ...[
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        endpoint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              footer,
            ],
          ),
        ),
      ),
    );
  }
}

String _protocolBadge(String protocol) => switch (protocol.toLowerCase()) {
  'shadowsocks' => 'SS',
  'shadowsocksr' => 'SSR',
  'vmess' => 'VM',
  'vless' => 'VLESS',
  'trojan' => 'TR',
  'hysteria' => 'HY',
  'hysteria2' => 'HY2',
  'tuic' => 'TUIC',
  'wireguard' => 'WG',
  'socks' => 'SOCKS',
  'http' => 'HTTP',
  'ssh' => 'SSH',
  'tor' => 'TOR',
  'anytls' => 'ANY',
  _ =>
    protocol.length <= 4
        ? protocol.toUpperCase()
        : protocol.substring(0, 3).toUpperCase(),
};

typedef NodeGroupOrder = ({
  String id,
  int index,
  int count,
  ValueChanged<int> move,
});

class ReorderableNodeGroup extends StatefulWidget {
  const ReorderableNodeGroup({
    super.key,
    required this.order,
    required this.enabled,
    required this.tooltip,
    required this.child,
  });

  final NodeGroupOrder order;
  final bool enabled;
  final String tooltip;
  final Widget child;
  static const leadingInset = 20.0;

  @override
  State<ReorderableNodeGroup> createState() => _ReorderableNodeGroupState();
}

class _ReorderableNodeGroupState extends State<ReorderableNodeGroup>
    with AutomaticKeepAliveClientMixin<ReorderableNodeGroup> {
  EdgeDraggingAutoScroller? _autoScroller;

  @override
  bool get wantKeepAlive => _autoScroller != null;

  void _stopAutoScroll() {
    _autoScroller?.stopAutoScroll();
    _autoScroller = null;
  }

  @override
  void dispose() {
    _stopAutoScroll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final (id: id, index: index, count: count, move: move) = widget.order;
    final labels = WidgetsLocalizations.of(context);
    final actions = <CustomSemanticsAction, VoidCallback>{
      if (widget.enabled && index > 0) ...{
        CustomSemanticsAction(label: labels.reorderItemUp): () =>
            move(index - 1),
        CustomSemanticsAction(label: labels.reorderItemToStart): () => move(0),
      },
      if (widget.enabled && index < count - 1) ...{
        CustomSemanticsAction(label: labels.reorderItemDown): () =>
            move(index + 1),
        CustomSemanticsAction(label: labels.reorderItemToEnd): () =>
            move(count - 1),
      },
    };
    final handle = Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.grab : MouseCursor.defer,
        child: SizedBox(
          width: 30,
          height: 44,
          child: Icon(
            Icons.drag_indicator_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: ReorderableNodeGroup.leadingInset,
          ),
          child: widget.child,
        ),
        Positioned(
          left: 0,
          child: Semantics(
            container: true,
            customSemanticsActions: actions,
            child: Draggable<String>(
              data: id,
              axis: Axis.vertical,
              affinity: Axis.vertical,
              maxSimultaneousDrags: widget.enabled ? 1 : 0,
              onDragStarted: () {
                _autoScroller = EdgeDraggingAutoScroller(
                  Scrollable.of(context),
                  velocityScalar: 40,
                );
                updateKeepAlive();
              },
              onDragUpdate: (details) {
                _autoScroller?.startAutoScrollIfNecessary(
                  Rect.fromCenter(
                    center: details.globalPosition,
                    width: 30,
                    height: 52,
                  ),
                );
              },
              onDragEnd: (_) {
                _stopAutoScroll();
                if (mounted) updateKeepAlive();
              },
              feedback: Material(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
                elevation: 4,
                child: const SizedBox(
                  width: 30,
                  height: 44,
                  child: Icon(Icons.drag_indicator_rounded),
                ),
              ),
              child: handle,
            ),
          ),
        ),
      ],
    );
  }
}

PopupMenuItem<T> nodeMenuItem<T>({
  required T value,
  required IconData icon,
  required String label,
  String? trailing,
  Color? color,
  bool enabled = true,
}) {
  return PopupMenuItem<T>(
    value: value,
    enabled: enabled,
    height: 38,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: _MenuRow(icon: icon, label: label, trailing: trailing, color: color),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.trailing,
    this.color,
  });

  final IconData icon;
  final String label;
  final String? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = color ?? scheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 17, color: color ?? scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: foreground,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 12),
          Text(
            trailing!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class NodeGroupEmpty extends StatelessWidget {
  const NodeGroupEmpty({
    super.key,
    this.filterActive = false,
    this.message = '暂无节点',
    this.addLabel = '添加节点',
    this.onFilter,
    this.onAdd,
    this.showAdd = false,
  });

  final bool filterActive;
  final String message;
  final String addLabel;
  final bool showAdd;
  final VoidCallback? onFilter;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 14, 16),
      child: Row(
        children: [
          Icon(
            filterActive ? Icons.filter_alt_off_outlined : Icons.inbox_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              filterActive ? '过滤后没有节点' : message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (filterActive && onFilter != null)
            TextButton(onPressed: onFilter, child: const Text('调整过滤'))
          else if (showAdd)
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(addLabel),
            ),
        ],
      ),
    );
  }
}

class NodeGroupActionButton extends StatelessWidget {
  const NodeGroupActionButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: nodeGroupActionStyle(scheme, background: false, size: 32),
      icon: child,
    );
  }
}

class NodeStatusTooltip extends StatelessWidget {
  const NodeStatusTooltip({
    super.key,
    required this.message,
    required this.child,
  });

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Keep adjacent tooltip overlays from sharing a semantics traversal parent.
    return Semantics(
      container: true,
      child: Tooltip(message: message, child: child),
    );
  }
}

class NodeLatency extends StatelessWidget {
  const NodeLatency({super.key, this.delay, this.error, this.testing = false});

  final int? delay;
  final String? error;
  final bool testing;

  @override
  Widget build(BuildContext context) {
    if (testing) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox.square(
          dimension: 12,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            semanticsLabel: '测速中',
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall;
    if (delay == null && error == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text('—', style: style?.copyWith(color: scheme.outline)),
      );
    }
    final color = switch ((error, delay)) {
      (null, final int value) when value < 150 => const Color(0xFF1B9E63),
      (null, final int value) when value < 350 => const Color(0xFFC68A00),
      _ => scheme.error,
    };
    final badge = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        error == null ? formatLatency(delay) : '失败',
        style: style?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
    if (error case final message?) {
      return NodeStatusTooltip(message: message, child: badge);
    }
    return badge;
  }
}
