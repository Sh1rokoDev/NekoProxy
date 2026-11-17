import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'header_icon_button.dart';

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
    this.maxContentWidth = defaultContentWidth,
    this.fadeTail = 20,
    this.scrollsBehindHeader = true,
  });

  static const defaultContentWidth = 820.0;
  static const _edge = 24.0;
  static const _actionGap = 8.0;

  final Widget title;
  final Widget Function(double headerInset) body;
  final List<Widget> actions;
  final double maxContentWidth;
  final double fadeTail;
  final bool scrollsBehindHeader;

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final hasBack = route?.impliesAppBarDismissal ?? false;
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final close = route is PageRoute<dynamic> && route.fullscreenDialog;

    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = ((constraints.maxWidth - maxContentWidth) / 2).clamp(
          _edge,
          double.infinity,
        );
        final narrowActions =
            actions.length >= 3 &&
            constraints.maxWidth <
                400 * MediaQuery.textScalerOf(context).scale(1);
        final toolbarActions = [
          for (final (index, action) in actions.indexed) ...[
            if (index > 0) const SizedBox(width: _actionGap),
            action,
          ],
        ];
        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: hasBack
                ? Padding(
                    padding: EdgeInsetsDirectional.only(start: gutter),
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
            title: title,
            titleTextStyle: theme.textTheme.titleLarge,
            titleSpacing: hasBack ? 12 : gutter,
            centerTitle: false,
            actions: narrowActions ? null : toolbarActions,
            actionsPadding: EdgeInsetsDirectional.only(end: gutter),
            bottom: narrowActions
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(
                      HeaderIconButton.size + _actionGap,
                    ),
                    child: Padding(
                      padding: EdgeInsetsDirectional.only(
                        start: gutter,
                        end: gutter,
                        bottom: _actionGap,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: toolbarActions,
                      ),
                    ),
                  )
                : null,
            forceMaterialTransparency: true,
          ),
          body: Builder(
            builder: (context) {
              final inset = MediaQuery.paddingOf(context).top;
              return SizedBox.expand(
                child: HeaderFade(
                  extent: inset + fadeTail,
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
