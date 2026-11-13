import 'package:flutter/material.dart';

import '../features/home/home_page.dart';
import '../features/nodes/nodes_page.dart';
import '../features/rules/rules_page.dart';
import '../features/tools/connections_page.dart';
import '../features/tools/tools_page.dart';
import '../state/app_controller.dart';
import 'app_scope.dart';
import 'navigation_dock.dart';
import 'widgets.dart';

const _destinations = [
  SlidingSegmentOption(
    value: 0,
    label: '首页',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
  ),
  SlidingSegmentOption(
    value: 1,
    label: '节点',
    icon: Icons.dns_outlined,
    selectedIcon: Icons.dns_rounded,
  ),
  SlidingSegmentOption(
    value: 2,
    label: '规则',
    icon: Icons.rule_outlined,
    selectedIcon: Icons.rule_rounded,
  ),
  SlidingSegmentOption(value: 3, label: '更多', icon: Icons.more_horiz_rounded),
];

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  AppController? _controller;
  int? _lastErrorRevision;
  int? _lastNoticeRevision;
  String? _lastLoadWarning;
  String? _lastRuleSetError;

  List<Widget> get _pages => [
    const HomePage(),
    const NodesPage(),
    const RulesPage(),
    const ToolsPage(),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppScope.read(context);
    if (!identical(_controller, controller)) {
      _controller?.removeListener(_onControllerChanged);
      _controller = controller;
      _lastErrorRevision = null;
      _lastNoticeRevision = null;
      _lastLoadWarning = null;
      _lastRuleSetError = null;
      controller.addListener(_onControllerChanged);
      _onControllerChanged();
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final controller = _controller;
    if (controller == null) return;
    final loadWarning = controller.loadWarning;
    if (loadWarning != _lastLoadWarning) {
      _lastLoadWarning = loadWarning;
      if (loadWarning != null) _showMessage(loadWarning, isError: true);
    }
    if (controller.errorRevision != _lastErrorRevision) {
      _lastErrorRevision = controller.errorRevision;
      final error = controller.error;
      if (error != null) _showMessage(error, isError: true);
    }
    final ruleSetError = controller.ruleSetError;
    if (ruleSetError != _lastRuleSetError) {
      _lastRuleSetError = ruleSetError;
      if (ruleSetError != null) _showMessage(ruleSetError, isError: true);
    }
    if (controller.noticeRevision != _lastNoticeRevision) {
      _lastNoticeRevision = controller.noticeRevision;
      final notice = controller.notice;
      if (notice != null) _showMessage(notice);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    final controller = _controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(controller, _controller)) return;
      final colors = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: isError ? TextStyle(color: colors.onError) : null,
          ),
          backgroundColor: isError ? colors.error : null,
          duration: Duration(seconds: isError ? 6 : 3),
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _openConnections() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ConnectionsPage()));
  }

  void _selectTab(int value) {
    if (value == _index) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _index = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ShellScope(
      switchTab: _selectTab,
      openConnections: _openConnections,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 900;
          final navigation = NavigationDock(
            axis: desktop ? Axis.vertical : Axis.horizontal,
            destinations: _destinations,
            selected: _index,
            onSelected: _selectTab,
          );
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  theme.colorScheme.surface,
                  theme.colorScheme.surfaceContainerLowest,
                  theme.colorScheme.surface,
                ],
              ),
            ),
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                top: false,
                bottom: desktop,
                child: Row(
                  textDirection: TextDirection.ltr,
                  children: [
                    if (desktop)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                        child: Align(child: navigation),
                      ),
                    Expanded(
                      key: const ValueKey('tab-content'),
                      child: _AnimatedTabStack(index: _index, children: _pages),
                    ),
                  ],
                ),
              ),
              bottomNavigationBar: desktop
                  ? null
                  : SafeArea(
                      top: false,
                      minimum: const EdgeInsets.fromLTRB(21, 12, 21, 21),
                      child: Align(heightFactor: 1, child: navigation),
                    ),
            ),
          );
        },
      ),
    );
  }
}

class _AnimatedTabStack extends StatefulWidget {
  const _AnimatedTabStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_AnimatedTabStack> createState() => _AnimatedTabStackState();
}

class _AnimatedTabStackState extends State<_AnimatedTabStack> {
  final _overlayKey = GlobalKey<OverlayState>();
  late final List<OverlayEntry> _entries;

  @override
  void initState() {
    super.initState();
    _entries = [
      for (var i = 0; i < widget.children.length; i++)
        OverlayEntry(
          opaque: i == widget.index,
          maintainState: true,
          builder: (context) => AnimatedOpacity(
            opacity: i == widget.index ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            onEnd: () {
              if (i == widget.index) _entries[i].opaque = true;
            },
            child: AnimatedScale(
              scale: i == widget.index ? 1 : 0.99,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: IgnorePointer(
                ignoring: i != widget.index,
                child: ExcludeSemantics(
                  excluding: i != widget.index,
                  child: TickerMode(
                    enabled: i == widget.index,
                    child: RepaintBoundary(child: widget.children[i]),
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
  }

  List<OverlayEntry> get _orderedEntries => [
    for (var i = 0; i < _entries.length; i++)
      if (i != widget.index) _entries[i],
    _entries[widget.index],
  ];

  @override
  void didUpdateWidget(_AnimatedTabStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      // Keep entries onstage during the fade, then let Overlay skip layout
      // of the retained pages below the opaque selected entry.
      for (final entry in _entries) {
        entry.opaque = false;
      }
      _overlayKey.currentState!.rearrange(_orderedEntries);
    }
    for (final entry in _entries) {
      entry.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.remove();
      entry.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Overlay(key: _overlayKey, initialEntries: _orderedEntries);
}
