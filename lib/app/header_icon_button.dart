import 'package:material_ui/material_ui.dart';

class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.label,
    this.onPressed,
    this.active = false,
    this.backgroundColor,
    this.foregroundColor,
  });

  static const size = 42.0;

  final IconData icon;
  final String tooltip;
  final String? label;
  final VoidCallback? onPressed;
  final bool active;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill =
        backgroundColor ??
        (active ? scheme.primaryContainer : scheme.surfaceContainerHighest);
    final foreground =
        foregroundColor ??
        (active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    if (label case final text?) {
      return Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: TextButton.icon(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, size),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: fill,
            disabledBackgroundColor: scheme.surfaceContainerHigh,
            foregroundColor: foreground,
            shape: shape,
          ),
          icon: Icon(icon, size: 18),
          label: Text(text),
        ),
      );
    }
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(size),
        fixedSize: const Size.square(size),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: fill,
        disabledBackgroundColor: scheme.surfaceContainerHigh,
        foregroundColor: foreground,
        shape: shape,
      ),
      icon: Icon(icon, size: 21),
    );
  }
}
