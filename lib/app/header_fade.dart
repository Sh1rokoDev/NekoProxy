import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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

/// A detail page with a standard Material toolbar and a soft body edge.
class HeaderScaffold extends StatelessWidget {
  const HeaderScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.fadeTail = 20,
    this.scrollsBehindHeader = true,
  });

  final Widget title;
  final Widget Function(double headerInset) body;
  final List<Widget>? actions;
  final double fadeTail;
  final bool scrollsBehindHeader;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: title,
        actions: actions,
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
  }
}
