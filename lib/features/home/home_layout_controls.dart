import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';

class EditableHomeCard extends StatelessWidget {
  const EditableHomeCard({
    super.key,
    required this.kind,
    required this.label,
    required this.enabled,
    required this.dragging,
    required this.onRemove,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.child,
  });

  final HomeCard kind;
  final String label;
  final bool enabled;
  final bool dragging;
  final VoidCallback onRemove;
  final ValueChanged<ScrollableState> onDragStarted;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shape = BorderRadius.circular(16);
    return LayoutBuilder(
      builder: (context, constraints) => LongPressDraggable<HomeCard>(
        data: kind,
        delay: const Duration(milliseconds: 50),
        maxSimultaneousDrags: enabled ? 1 : 0,
        hitTestBehavior: HitTestBehavior.opaque,
        onDragStarted: () => onDragStarted(Scrollable.of(context)),
        onDragUpdate: (details) => onDragUpdate(details.globalPosition),
        onDraggableCanceled: (_, _) => onDragEnd(),
        onDragCompleted: onDragEnd,
        feedback: SizedBox(
          width: constraints.maxWidth,
          child: Material(
            elevation: 8,
            color: colors.surface,
            borderRadius: shape,
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        ),
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.grab : SystemMouseCursors.basic,
          child: Stack(
            children: [
              Visibility(
                visible: !dragging,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: ExcludeFocus(child: IgnorePointer(child: child)),
              ),
              if (dragging)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.primaryContainer.withValues(alpha: 0.3),
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: shape,
                    ),
                  ),
                )
              else
                PositionedDirectional(
                  top: 4,
                  end: 4,
                  child: Material(
                    color: colors.surfaceContainerHighest,
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: '移除$label',
                      onPressed: enabled ? onRemove : null,
                      style: IconButton.styleFrom(
                        fixedSize: const Size.square(36),
                        minimumSize: const Size.square(36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                      ),
                      icon: const Icon(Icons.close_rounded, size: 18),
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

class AddHomeCardButton extends StatelessWidget {
  const AddHomeCardButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _DashedCardBorder(colors.outline),
      child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size.fromHeight(72),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加卡片'),
      ),
    );
  }
}

class _DashedCardBorder extends CustomPainter {
  const _DashedCardBorder(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(1),
          const Radius.circular(16),
        ),
      );
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      for (var start = 0.0; start < metric.length; start += 10) {
        canvas.drawPath(metric.extractPath(start, start + 6), stroke);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedCardBorder oldDelegate) =>
      oldDelegate.color != color;
}
