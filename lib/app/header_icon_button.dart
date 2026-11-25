import 'package:material_ui/material_ui.dart';

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

  static const size = 42.0;

  final IconData icon;
  final String tooltip;
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
        foregroundColor:
            foregroundColor ??
            (active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      icon: Icon(icon, size: 21),
    );
  }
}
