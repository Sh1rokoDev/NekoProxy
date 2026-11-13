import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

class SlidingSegmentOption<T> {
  const SlidingSegmentOption({
    required this.value,
    required this.label,
    this.icon,
    this.selectedIcon,
  });

  final T value;
  final String label;
  final IconData? icon;
  final IconData? selectedIcon;
}

/// A segmented control whose selection lifts and springs under the pointer.
class SlidingSegmentedControl<T> extends StatefulWidget {
  const SlidingSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    required this.width,
    this.height = 42,
    this.axis = Axis.horizontal,
    this.navigation = false,
  });

  final List<SlidingSegmentOption<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;
  final double width;
  final double height;
  final Axis axis;

  /// Uses stacked labels and the larger navigation surface.
  final bool navigation;

  @override
  State<SlidingSegmentedControl<T>> createState() =>
      _SlidingSegmentedControlState<T>();
}

class _SlidingSegmentedControlState<T> extends State<SlidingSegmentedControl<T>>
    with TickerProviderStateMixin {
  static const _inset = 4.0;
  static const _pill = BorderRadius.all(Radius.circular(999));
  static final _travel = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 400),
    bounce: 0.15,
  );
  static final _follow = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 1024,
    ratio: 0.9,
  );
  static final _release = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 380),
    bounce: 0.24,
  );
  static const _rest = Tolerance(distance: 0.001, velocity: 0.025);

  late final AnimationController _lift = AnimationController.unbounded(
    vsync: this,
    debugLabel: 'Segment lift',
  );
  late final ValueNotifier<double> _position = ValueNotifier(
    _selectedIndex.toDouble(),
  );
  late final Ticker _ticker = createTicker(_tick);
  late final Listenable _motion = Listenable.merge([_position, _lift]);
  SpringSimulation? _flight;
  double _target = 0;
  double _velocity = 0;
  double _now = 0;
  double _flightStart = 0;
  bool _landing = false;
  int? _pointer;
  int? _preview;
  double _down = 0;
  double _crossDown = 0;
  bool _dragging = false;
  VelocityTracker? _tracker;

  bool get _reduced => MediaQuery.disableAnimationsOf(context);
  bool get _vertical => widget.axis == Axis.vertical;
  int get _last => widget.segments.length - 1;
  int get _selectedIndex => math.max(
    0,
    widget.segments.indexWhere((segment) => segment.value == widget.selected),
  );

  void _select(int index) {
    final value = widget.segments[index].value;
    if (value != widget.selected) widget.onChanged?.call(value);
  }

  @override
  void initState() {
    super.initState();
    _lift.addListener(_maybeLand);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduced) _resetMotion();
  }

  @override
  void didUpdateWidget(SlidingSegmentedControl<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.axis != oldWidget.axis ||
        widget.segments.length != oldWidget.segments.length ||
        (widget.onChanged == null && _pointer != null)) {
      _pointer = null;
      _tracker = null;
      _preview = null;
      _resetMotion();
    } else if (widget.selected != oldWidget.selected && _pointer == null) {
      _move(_selectedIndex.toDouble(), _travel);
    }
  }

  void _resetMotion() {
    _ticker.stop();
    _flight = null;
    _velocity = 0;
    _landing = false;
    _lift.value = 0;
    _position.value = (_preview ?? _selectedIndex).toDouble();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _position.dispose();
    _lift.dispose();
    super.dispose();
  }

  void _move(double target, SpringDescription spring) {
    if (_reduced) {
      _position.value = target;
      return;
    }
    if (_flight != null && _target == target) return;
    if (_position.value == target && _velocity == 0) {
      _flight = null;
      _ticker.stop();
      return;
    }
    _target = target;
    _flight = SpringSimulation(
      spring,
      _position.value,
      target,
      _velocity,
      tolerance: _rest,
    );
    // Retarget the running spring without resetting the frame clock.
    if (!_ticker.isActive) {
      _now = 0;
      _ticker.start();
    }
    _flightStart = _now;
  }

  void _tick(Duration elapsed) {
    _now = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final flight = _flight;
    if (flight == null) return;
    final time = _now - _flightStart;
    if (flight.isDone(time)) {
      _flight = null;
      _ticker.stop();
      _velocity = 0;
      _position.value = _target;
    } else {
      _velocity = flight.dx(time);
      _position.value = flight.x(time);
    }
    _maybeLand();
  }

  void _maybeLand() {
    if (!_landing || _lift.value < 0.97) return;
    if (_flight != null && (_position.value - _target).abs() > 0.04) return;
    _landing = false;
    _lift.animateWith(
      SpringSimulation(
        _release,
        _lift.value,
        0,
        _lift.velocity,
        tolerance: _rest,
      ),
    );
  }

  double _coordinate(Offset point, Size size, bool rtl) =>
      _vertical ? point.dy : (rtl ? size.width - point.dx : point.dx);

  double _crossCoordinate(Offset point) => _vertical ? point.dx : point.dy;

  double _indexAt(double coordinate, double pitch) => pitch <= 0
      ? _selectedIndex.toDouble()
      : (coordinate - _inset) / pitch - 0.5;

  double _resisted(double index) {
    final edge = index.clamp(0.0, _last.toDouble());
    final excess = index - edge;
    return edge + excess * 0.36 / (0.65 + excess.abs());
  }

  void _downOn(PointerDownEvent event, double coordinate, double pitch) {
    if (widget.onChanged == null ||
        _pointer != null ||
        event.buttons != kPrimaryButton) {
      return;
    }
    _pointer = event.pointer;
    _tracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
    _down = coordinate;
    _crossDown = _crossCoordinate(event.localPosition);
    _dragging = false;
    _landing = false;
    final index = _indexAt(coordinate, pitch).round().clamp(0, _last);
    _preview = index;
    if (!_reduced) {
      _lift.animateWith(
        SpringSimulation(
          _travel,
          _lift.value,
          1,
          _lift.velocity,
          tolerance: _rest,
        ),
      );
    }
    _move(index.toDouble(), _travel);
  }

  void _movePointer(PointerMoveEvent event, double coordinate, double pitch) {
    if (_pointer != event.pointer) return;
    _tracker?.addPosition(event.timeStamp, event.localPosition);
    if (!_dragging) {
      final slop = computeHitSlop(event.kind, null);
      final along = (coordinate - _down).abs();
      final across = (_crossCoordinate(event.localPosition) - _crossDown).abs();
      // Compact segments can sit inside a scrollable page.
      if (!widget.navigation && across > slop && across > along) {
        _finish();
        return;
      }
      if (along < slop) return;
    }
    _dragging = true;
    final index = _indexAt(coordinate, pitch);
    final preview = index.round().clamp(0, _last);
    if (preview != _preview) HapticFeedback.selectionClick();
    _preview = preview;
    _move(_resisted(index), _follow);
  }

  void _end(PointerEvent event, double coordinate, double pitch, bool rtl) {
    final preview = _preview;
    if (_pointer != event.pointer || preview == null) return;
    var index = preview;
    final commit = event is PointerUpEvent;
    if (commit && _dragging && pitch > 0) {
      final velocity = _tracker?.getVelocity().pixelsPerSecond ?? Offset.zero;
      final speed = _vertical ? velocity.dy : velocity.dx * (rtl ? -1 : 1);
      index = (_indexAt(coordinate, pitch) + speed * 0.1 / pitch)
          .round()
          .clamp(preview - 1, preview + 1)
          .clamp(0, _last);
      if (index != preview) HapticFeedback.selectionClick();
    }
    _finish(index: commit ? index : null);
  }

  void _finish({int? index}) {
    _pointer = null;
    _tracker = null;
    _preview = null;
    _landing = !_reduced;
    _move(
      (_reduced ? _selectedIndex : index ?? _selectedIndex).toDouble(),
      _travel,
    );
    _maybeLand();
    if (index != null) _select(index);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rtl = !_vertical && Directionality.of(context) == TextDirection.rtl;
    if (widget.segments.isEmpty) return const SizedBox.shrink();
    final navigation = widget.navigation;
    final growth = navigation ? 16.0 : 8.0;
    return RepaintBoundary(
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final span = _vertical ? size.height : size.width;
            final cross = _vertical ? size.width : size.height;
            final pitch =
                math.max(0.0, span - 2 * _inset) / widget.segments.length;
            return Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) => _downOn(
                event,
                _coordinate(event.localPosition, size, rtl),
                pitch,
              ),
              onPointerMove: (event) => _movePointer(
                event,
                _coordinate(event.localPosition, size, rtl),
                pitch,
              ),
              onPointerUp: (event) => _end(
                event,
                _coordinate(event.localPosition, size, rtl),
                pitch,
                rtl,
              ),
              onPointerCancel: (event) => _end(event, 0, pitch, rtl),
              child: AnimatedBuilder(
                animation: _motion,
                builder: (context, _) {
                  final lift = _lift.value.clamp(0.0, 1.15);
                  final position = _position.value;
                  final stretch = (_velocity.abs() / 40).clamp(0.0, 0.16);
                  final overrun =
                      position - position.clamp(0.0, _last.toDouble());
                  final pull =
                      (_reduced ? 0.0 : overrun * pitch * 0.35) *
                      (rtl ? -1 : 1);
                  final axisScale =
                      1 +
                      (growth * lift + pull.abs() * 0.5) / math.max(span, 1);
                  final crossScale = 1 + 0.045 * lift;
                  // At rest the end segments share the same inset on both axes.
                  final extent = (pitch + growth * lift) * (1 + stretch);
                  final thickness = math.max(
                    0.0,
                    (cross - 2 * _inset + growth * lift) * (1 - 0.75 * stretch),
                  );
                  final center = _inset + pitch * (position + 0.5);
                  final along = rtl ? span - center : center;
                  final lens = Rect.fromCenter(
                    center: _vertical
                        ? Offset(cross / 2, along)
                        : Offset(along, cross / 2),
                    width: _vertical ? thickness : extent,
                    height: _vertical ? extent : thickness,
                  );
                  return Transform.translate(
                    offset: _vertical ? Offset(0, pull) : Offset(pull, 0),
                    transformHitTests: false,
                    child: Transform.scale(
                      scaleX: _vertical ? crossScale : axisScale,
                      scaleY: _vertical ? axisScale : crossScale,
                      transformHitTests: false,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: _pill,
                          border: navigation
                              ? null
                              : Border.all(
                                  color: scheme.outlineVariant.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                          boxShadow: navigation
                              ? [
                                  BoxShadow(
                                    color: scheme.shadow.withValues(
                                      alpha: 0.13,
                                    ),
                                    blurRadius: 24,
                                    offset: const Offset(0, 8),
                                  ),
                                ]
                              : null,
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fromRect(
                              key: const ValueKey('segment-highlight'),
                              rect: lens,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: !navigation
                                      ? scheme.secondaryContainer
                                      : Color.lerp(
                                          scheme.surfaceContainerHighest,
                                          scheme.secondaryContainer,
                                          lift.clamp(0.0, 1.0) * 0.45,
                                        ),
                                  borderRadius: _pill,
                                  boxShadow: [
                                    BoxShadow(
                                      color: scheme.shadow.withValues(
                                        alpha: 0.14 * lift,
                                      ),
                                      blurRadius: 8 * lift,
                                      offset: Offset(0, 3 * lift),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(_inset),
                              child: Flex(
                                direction: widget.axis,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final (index, destination)
                                      in widget.segments.indexed)
                                    Expanded(
                                      child: _SegmentLabel(
                                        destination: destination,
                                        selected: _selectedIndex == index,
                                        navigation: navigation,
                                        emphasis: (1 - (position - index).abs())
                                            .clamp(0.0, 1.0),
                                        lift: lift,
                                        onActivate: widget.onChanged == null
                                            ? null
                                            : () => _select(index),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SegmentLabel extends StatefulWidget {
  const _SegmentLabel({
    required this.destination,
    required this.selected,
    required this.emphasis,
    required this.navigation,
    required this.lift,
    required this.onActivate,
  });

  final SlidingSegmentOption<Object?> destination;
  final bool navigation;
  final bool selected;
  final double emphasis;
  final double lift;
  final VoidCallback? onActivate;

  @override
  State<_SegmentLabel> createState() => _SegmentLabelState();
}

class _SegmentLabelState extends State<_SegmentLabel> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final destination = widget.destination;
    final color = Color.lerp(
      scheme.onSurfaceVariant,
      widget.navigation ? scheme.primary : scheme.onSecondaryContainer,
      widget.emphasis,
    );
    return FocusableActionDetector(
      enabled: widget.onActivate != null,
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onActivate?.call();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        selected: widget.selected,
        enabled: widget.onActivate != null,
        label: destination.label,
        excludeSemantics: true,
        inMutuallyExclusiveGroup: true,
        onTap: widget.onActivate,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: StadiumBorder(
              side: _focused
                  ? BorderSide(color: scheme.primary, width: 2)
                  : BorderSide.none,
            ),
          ),
          child: Center(
            child: Transform.scale(
              scale: 1 + 0.12 * widget.lift * widget.emphasis,
              transformHitTests: false,
              child: widget.navigation
                  ? FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            destination.selectedIcon ?? destination.icon,
                            size: 28,
                            color: color,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            destination.label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: color,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (destination.icon != null) ...[
                            Icon(destination.icon, size: 15, color: color),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              destination.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: color,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
