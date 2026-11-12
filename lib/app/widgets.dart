import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PageFrame extends StatelessWidget {
  const PageFrame({
    super.key,
    required this.title,
    required this.child,
    this.scrollable = true,
    this.floatingActionButton,
    this.actions,
    this.wrapHeader = false,
  });

  final String title;
  final Widget child;
  final bool scrollable;
  final Widget? floatingActionButton;
  final Widget? actions;
  final bool wrapHeader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        22,
        24,
        scrollable ? (floatingActionButton == null ? 32 : 104) : 0,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  if (wrapHeader && constraints.maxWidth < 400) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.headlineSmall),
                        if (actions != null) ...[
                          const SizedBox(height: 12),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: actions!,
                          ),
                        ],
                      ],
                    );
                  }
                  return SizedBox(
                    height: 48,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall,
                          ),
                        ),
                        if (actions != null) ...[
                          const SizedBox(width: 12),
                          actions!,
                        ],
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
              child,
            ],
          ),
        ),
      ),
    );
    final Widget body = scrollable
        ? SingleChildScrollView(child: content)
        : content;
    if (floatingActionButton == null) return body;
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned(right: 24, bottom: 24, child: floatingActionButton!),
      ],
    );
  }
}

class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.active = false,
    this.backgroundColor,
    this.foregroundColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(42, 42),
        fixedSize: const Size(42, 42),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor:
            backgroundColor ??
            (active
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest.withValues(alpha: 0.7)),
        foregroundColor:
            foregroundColor ??
            (active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: Icon(icon, size: 21),
    );
  }
}

class SlidingSegmentOption<T> {
  const SlidingSegmentOption({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
}

/// Single-pill segmented control whose selection slides horizontally.
class SlidingSegmentedControl<T> extends StatelessWidget {
  const SlidingSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    required this.width,
    this.height = 42,
  });

  final List<SlidingSegmentOption<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;
  final double height;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final index = segments.indexWhere((segment) => segment.value == selected);
    final active = index < 0 ? 0 : index;
    final alignment = segments.length <= 1
        ? Alignment.center
        : Alignment(-1 + 2 * active / (segments.length - 1), 0);
    final control = Container(
      height: height,
      padding: const EdgeInsets.all(3),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: AnimatedAlign(
                alignment: alignment,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: FractionallySizedBox(
                  widthFactor: 1 / segments.length,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final segment in segments)
                  Expanded(
                    child: _SlidingSegment(
                      label: segment.label,
                      icon: segment.icon,
                      active: segment.value == selected,
                      onTap: onChanged == null
                          ? null
                          : () => onChanged!(segment.value),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return SizedBox(width: width, child: control);
  }
}

class _SlidingSegment extends StatelessWidget {
  const _SlidingSegment({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = active
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: active,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: foreground),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    style:
                        theme.textTheme.labelMedium?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w600,
                        ) ??
                        TextStyle(color: foreground),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.icon,
    this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.color,
  });

  final IconData? icon;
  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasHeader = title != null || trailing != null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: color ?? theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasHeader)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      title ?? '',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          Padding(
            padding: hasHeader
                ? EdgeInsets.fromLTRB(
                    padding.left,
                    0,
                    padding.right,
                    padding.bottom,
                  )
                : padding,
            child: child,
          ),
        ],
      ),
    );
  }
}

class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.active, this.color, this.size = 8});
  final bool active;
  final Color? color;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ??
        (widget.active
            ? const Color(0xFF1B9E63)
            : Theme.of(context).colorScheme.outline);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final glow = widget.active ? 0.23 + _controller.value * 0.25 : 0.0;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: widget.active
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: glow),
                      blurRadius: 10,
                      spreadRadius: 5,
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}

class TrafficSparkline extends StatelessWidget {
  const TrafficSparkline({
    super.key,
    required this.up,
    required this.down,
    this.height = 56,
    this.showGrid = true,
  });

  final List<double> up;
  final List<double> down;
  final double height;
  final bool showGrid;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _SparklinePainter(
          up: up,
          down: down,
          upColor: scheme.primary,
          downColor: scheme.tertiary,
          gridColor: scheme.outlineVariant,
          showGrid: showGrid,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.up,
    required this.down,
    required this.upColor,
    required this.downColor,
    required this.gridColor,
    required this.showGrid,
  });

  final List<double> up;
  final List<double> down;
  final Color upColor;
  final Color downColor;
  final Color gridColor;
  final bool showGrid;

  @override
  void paint(Canvas canvas, Size size) {
    final maxValue = math.max(1.0, [...up, ...down].fold<double>(0, math.max));
    const top = 6.0;
    final bottom = size.height - 4;
    final chartHeight = bottom - top;

    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: showGrid ? 0.5 : 0.35)
      ..strokeWidth = 1;
    if (showGrid) {
      for (var i = 1; i <= 3; i++) {
        final y = top + chartHeight * i / 4;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      }
    }
    canvas.drawLine(Offset(0, bottom), Offset(size.width, bottom), gridPaint);

    void draw(List<double> data, Color color) {
      if (data.isEmpty) return;
      final step = data.length <= 1 ? 0.0 : size.width / (data.length - 1);
      final points = <Offset>[
        for (var i = 0; i < data.length; i++)
          Offset(
            data.length <= 1 ? size.width : step * i,
            bottom - (data[i] / maxValue).clamp(0.0, 1.0) * chartHeight,
          ),
      ];
      final path = _smoothPath(points, top, bottom);
      final fill = Path.from(path)
        ..lineTo(points.last.dx, bottom)
        ..lineTo(points.first.dx, bottom)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.20),
              color.withValues(alpha: 0.0),
            ],
          ).createShader(Offset.zero & size),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = color,
      );
    }

    draw(down, downColor);
    draw(up, upColor);
  }

  Path _smoothPath(List<Offset> points, double minY, double maxY) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length - 1; i++) {
      final previous = i == 0 ? points[i] : points[i - 1];
      final start = points[i];
      final end = points[i + 1];
      final next = i + 2 < points.length ? points[i + 2] : end;
      final control1 = Offset(
        start.dx + (end.dx - previous.dx) / 6,
        (start.dy + (end.dy - previous.dy) / 6).clamp(minY, maxY),
      );
      final control2 = Offset(
        end.dx - (next.dx - start.dx) / 6,
        (end.dy - (next.dy - start.dy) / 6).clamp(minY, maxY),
      );
      path.cubicTo(
        control1.dx,
        control1.dy,
        control2.dx,
        control2.dy,
        end.dx,
        end.dy,
      );
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.up != up ||
      oldDelegate.down != down ||
      oldDelegate.upColor != upColor ||
      oldDelegate.downColor != downColor ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.showGrid != showGrid;
}

class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.expandValue = false,
  });
  final String label;
  final String value;
  final IconData? icon;
  final bool expandValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelText = Text(
      label,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 9),
          ],
          if (expandValue) labelText else Expanded(child: labelText),
          const SizedBox(width: 12),
          Flexible(
            fit: expandValue ? FlexFit.tight : FlexFit.loose,
            child: SelectableText(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 44),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              icon,
              size: 28,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    );
  }
}

class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: enabled ? () => onChanged?.call(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 20,
                color: enabled
                    ? theme.colorScheme.primary
                    : theme.disabledColor,
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(value: value, onChanged: enabled ? onChanged : null),
          ],
        ),
      ),
    );
  }
}

String formatBytes(num bytes, {int decimals = 1}) {
  if (bytes.isNaN || bytes.isInfinite || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  final digits = index == 0 ? 0 : decimals;
  return '${value.toStringAsFixed(digits)} ${units[index]}';
}

String formatSpeed(double bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

String formatDuration(Duration duration) {
  if (duration.inSeconds < 60) return '${duration.inSeconds} 秒';
  if (duration.inMinutes < 60) return '${duration.inMinutes} 分钟';
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  if (hours < 24) return minutes == 0 ? '$hours 小时' : '$hours 小时 $minutes 分';
  final days = duration.inDays;
  return '$days 天 ${hours % 24} 小时';
}

String formatDate(DateTime? date) {
  if (date == null) return '未记录';
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

String formatLatency(int? delay) {
  if (delay == null) return '—';
  if (delay <= 0) return '<1ms';
  if (delay < 1000) return '${delay}ms';
  final seconds = delay / 1000;
  return '${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)}s';
}

Future<void> copyText(
  BuildContext context,
  String text, {
  String message = '已复制',
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}
