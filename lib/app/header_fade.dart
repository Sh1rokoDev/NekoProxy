import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'header_icon_button.dart';

abstract final class PageHeaderLayout {
  static const verticalPadding = 20.0;
  static const rowGap = 12.0;
  static const fadeTail = 12.0;

  static double rowHeightOf(BuildContext context) {
    final style = Theme.of(context).textTheme.headlineSmall;
    final fontSize = MediaQuery.textScalerOf(context)
        .scale(style?.fontSize ?? 24);
    final lineHeight = fontSize * (style?.height ?? 4 / 3);
    return math.max(48, lineHeight.ceilToDouble());
  }
}

/// A full-height viewport with a frosted overlay starting at its top edge.
class HeaderFade extends StatelessWidget {
  const HeaderFade({super.key, required this.child, required this.extent});

  final Widget child;
  final double extent;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: extent,
          child: const HeaderFrost(),
        ),
      ],
    );
  }
}

/// The background of a pinned header, painted independently of its controls.
class HeaderFrost extends StatelessWidget {
  const HeaderFrost({super.key});

  static final _blur = ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6);

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).scaffoldBackgroundColor;
    return IgnorePointer(
      child: ClipRect(
        child: BackdropFilter(
          filter: _blur,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Mask the filtered pixels in the backdrop layer itself,
              // so the unfiltered content returns gradually at the edge.
              const DecoratedBox(
                decoration: BoxDecoration(
                  backgroundBlendMode: BlendMode.dstIn,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white,
                      Color(0x99FFFFFF),
                      Colors.transparent,
                    ],
                    stops: [0, 0.65, 1],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      surface.withValues(alpha: 0.96),
                      surface.withValues(alpha: 0.86),
                      surface.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.55, 1],
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

/// A detail toolbar aligned with its content and clear of system insets.
class HeaderScaffold extends StatelessWidget {
  const HeaderScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.floatingActionButton,
    this.maxContentWidth = defaultContentWidth,
    this.scrollsBehindHeader = true,
  });

  static const defaultContentWidth = 820.0;
  static const _edge = 24.0;
  static const _actionGap = 8.0;

  final Widget title;
  final Widget Function(double headerInset) body;
  final List<Widget> actions;
  final Widget? floatingActionButton;

  final double maxContentWidth;
  final bool scrollsBehindHeader;

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final hasBack = route?.impliesAppBarDismissal ?? false;
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final close = route is PageRoute<dynamic> && route.fullscreenDialog;
    final textScaler = MediaQuery.textScalerOf(context);
    final rowHeight = PageHeaderLayout.rowHeightOf(context);
    const verticalPadding = PageHeaderLayout.verticalPadding;

    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = ((constraints.maxWidth - maxContentWidth) / 2).clamp(
          _edge,
          double.infinity,
        );
        final narrowActions =
            actions.length >= 3 &&
            constraints.maxWidth < 400 * textScaler.scale(1);
        final toolbarActions = [
          for (final (index, action) in actions.indexed) ...[
            if (index > 0) const SizedBox(width: _actionGap),
            action,
          ],
        ];
        return Scaffold(
          extendBodyBehindAppBar: true,
          floatingActionButton: floatingActionButton,
          appBar: AppBar(
            toolbarHeight: verticalPadding + rowHeight,
            automaticallyImplyLeading: false,
            leading: hasBack
                ? Padding(
                    padding: EdgeInsetsDirectional.only(
                      top: verticalPadding,
                      start: gutter,
                    ),
                    child: Center(
                      child: HeaderIconButton(
                        icon: close
                            ? Icons.close_rounded
                            : Icons.arrow_back_rounded,
                        tooltip: close
                            ? localizations.closeButtonTooltip
                            : localizations.backButtonTooltip,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  )
                : null,
            leadingWidth: gutter + HeaderIconButton.size,
            title: Padding(
              padding: const EdgeInsets.only(top: verticalPadding),
              child: Builder(
                // AppBar clamps title scaling. Use the same scale as PageFrame.
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                  child: DefaultTextStyle.merge(maxLines: 1, child: title),
                ),
              ),
            ),
            titleTextStyle: theme.textTheme.headlineSmall,
            titleSpacing: hasBack ? 12 : gutter,
            centerTitle: false,
            actions: narrowActions ? null : toolbarActions,
            actionsPadding: EdgeInsetsDirectional.only(
              top: verticalPadding,
              end: gutter,
            ),
            bottom: PreferredSize(
              preferredSize: Size.fromHeight(
                verticalPadding +
                    (narrowActions
                        ? PageHeaderLayout.rowGap + HeaderIconButton.size
                        : 0),
              ),
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: gutter,
                  end: gutter,
                  top: narrowActions ? PageHeaderLayout.rowGap : 0,
                  bottom: verticalPadding,
                ),
                child: narrowActions
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: toolbarActions,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            forceMaterialTransparency: true,
          ),
          body: Builder(
            builder: (context) {
              final inset = MediaQuery.paddingOf(context).top;
              return SizedBox.expand(
                child: HeaderFade(
                  extent: inset + PageHeaderLayout.fadeTail,
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: scrollsBehindHeader
                        ? body(inset)
                        : Padding(
                            padding: EdgeInsets.only(top: inset),
                            child: body(0),
                          ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
