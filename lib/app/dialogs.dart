import 'package:material_ui/material_ui.dart';

enum AppDialogSize {
  compact(360),
  standard(480),
  wide(640);

  const AppDialogSize(this.width);

  final double width;
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showDialog<T>(
  context: context,
  barrierColor: _modalBarrierColor(context),
  builder: builder,
);

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  bool destructive = false,
}) async {
  final result = await showAppDialog<bool>(
    context: context,
    builder: (context) {
      final colors = Theme.of(context).colorScheme;
      return AppDialog(
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
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result == true;
}

class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    this.content,
    this.actions = const [],
    this.leadingAction,
    this.size = AppDialogSize.compact,
    this.scrollContent = true,
    this.canClose = true,
  });

  final Widget title;
  final Widget? content;
  final List<Widget> actions;
  final Widget? leadingAction;
  final AppDialogSize size;

  /// Set to false when the content provides its own bounded scroll view.
  final bool scrollContent;

  final bool canClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final content = this.content;
    final dark = theme.brightness == Brightness.dark;
    final line = colors.outlineVariant.withValues(alpha: 0.65);
    const controlRadius = BorderRadius.all(Radius.circular(8));
    final inputBorder = OutlineInputBorder(
      borderRadius: controlRadius,
      borderSide: BorderSide(color: colors.outline),
    );
    final buttonStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(48, 40)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      ),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: controlRadius),
      ),
    );

    return Dialog(
      backgroundColor: colors.surfaceContainerLow,
      elevation: dark ? 0 : 6,
      shadowColor: colors.shadow.withValues(alpha: 0.18),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: _modalRadius,
        side: BorderSide(color: line),
      ),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      constraints: BoxConstraints(maxWidth: size.width),
      child: SizedBox(
        width: size.width,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final inset = constraints.maxWidth < 340 ? 16.0 : 20.0;
            final header = _ModalHeader(
              title: title,
              inset: inset,
              canClose: canClose,
            );
            final body = content == null
                ? null
                : Padding(
                    padding: EdgeInsets.fromLTRB(inset, 6, inset, 16),
                    child: DefaultTextStyle.merge(
                      style: theme.textTheme.bodyMedium,
                      child: content,
                    ),
                  );
            final footer = actions.isEmpty && leadingAction == null
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(height: 1, color: line),
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: inset,
                          vertical: 6,
                        ),
                        child: OverflowBar(
                          spacing: 8,
                          overflowSpacing: 4,
                          overflowAlignment: OverflowBarAlignment.end,
                          alignment: leadingAction == null
                              ? MainAxisAlignment.end
                              : MainAxisAlignment.spaceBetween,
                          children: [
                            ?leadingAction,
                            Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 8,
                              runSpacing: 4,
                              children: actions,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
            // Keep the controls reachable if the keyboard or split screen
            // leaves less space than the header and action bar need together.
            final shortViewport = constraints.maxHeight < 200;
            final panel = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                if (body != null)
                  if (shortViewport)
                    body
                  else
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 520),
                        child: scrollContent
                            ? SingleChildScrollView(child: body)
                            : body,
                      ),
                    ),
                ?footer,
              ],
            );
            return Theme(
              data: theme.copyWith(
                inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                  filled: true,
                  fillColor: colors.surfaceContainer,
                  border: inputBorder,
                  enabledBorder: inputBorder,
                  focusedBorder: inputBorder.copyWith(
                    borderSide: BorderSide(color: colors.primary, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                textButtonTheme: TextButtonThemeData(
                  style: buttonStyle.copyWith(
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.disabled)
                          ? null
                          : colors.onSurface;
                    }),
                  ),
                ),
                filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
                outlinedButtonTheme: OutlinedButtonThemeData(
                  style: buttonStyle,
                ),
              ),
              child: shortViewport
                  ? SingleChildScrollView(child: panel)
                  : panel,
            );
          },
        ),
      ),
    );
  }
}

typedef AppModalOption<T> = ({T value, IconData icon, String label});

Future<T?> showAppChoice<T>({
  required BuildContext context,
  required String title,
  required List<AppModalOption<T>> options,
}) => showAppDialog<T>(
  context: context,
  builder: (context) => AppDialog(
    title: Text(title),
    content: _ModalOptions(options: options),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  ),
);

Future<T?> showAppSheet<T>({
  required BuildContext context,
  required String title,
  required List<AppModalOption<T>> options,
  String? emptyLabel,
}) => showModalBottomSheet<T>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  showDragHandle: true,
  barrierColor: _modalBarrierColor(context),
  constraints: const BoxConstraints(maxWidth: 448),
  backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
  shape: RoundedRectangleBorder(
    borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
    side: BorderSide(
      color: Theme.of(context).colorScheme.outlineVariant
          .withValues(alpha: 0.65),
    ),
  ),
  clipBehavior: Clip.antiAlias,
  builder: (context) => SafeArea(
    top: false,
    child: SizedBox(
      width: 448,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ModalHeader(title: Text(title), inset: 20),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: options.isEmpty && emptyLabel != null
                  ? Text(emptyLabel)
                  : _ModalOptions(options: options),
            ),
          ),
        ],
      ),
    ),
  ),
);

class _ModalHeader extends StatelessWidget {
  const _ModalHeader({
    required this.title,
    required this.inset,
    this.canClose = true,
  });

  final Widget title;
  final double inset;
  final bool canClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(inset, 4, inset - 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              namesRoute: true,
              child: DefaultTextStyle.merge(
                style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                child: title,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            color: theme.colorScheme.onSurfaceVariant,
            onPressed: canClose ? () => Navigator.maybePop(context) : null,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _ModalOptions<T> extends StatelessWidget {
  const _ModalOptions({required this.options});

  final List<AppModalOption<T>> options;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in options)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            minTileHeight: 48,
            minLeadingWidth: 18,
            horizontalTitleGap: 10,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            iconColor: theme.colorScheme.onSurfaceVariant,
            titleTextStyle: theme.textTheme.bodyMedium,
            leading: Icon(option.icon, size: 18),
            title: Text(option.label),
            trailing: const Icon(Icons.chevron_right_rounded, size: 18),
            onTap: () => Navigator.pop(context, option.value),
          ),
      ],
    );
  }
}

class AppDialogCode extends StatelessWidget {
  const AppDialogCode(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          text,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

const _modalRadius = BorderRadius.all(Radius.circular(16));

Color _modalBarrierColor(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Colors.black.withValues(alpha: dark ? 0.6 : 0.35);
}
