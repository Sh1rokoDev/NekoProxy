import 'package:material_ui/material_ui.dart';

import '../features/home/home_page.dart';
import '../features/nodes/nodes_page.dart';
import '../features/rules/rules_page.dart';
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
    if (!controller.showsRuleMode && _index == 2) _index = 0;
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

  void _selectTab(int value) {
    if (value == 2 && _controller?.showsRuleMode == false) return;
    if (value == _index) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _index = value);
  }

  @override
  Widget build(BuildContext context) {
    final showsRuleMode = AppScope.of(context).showsRuleMode;
    final selected = !showsRuleMode && _index == 2 ? 0 : _index;
    final useSideDock =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final navigation = NavigationDock(
      axis: useSideDock ? Axis.vertical : Axis.horizontal,
      destinations: showsRuleMode
          ? _destinations
          : _destinations.where((item) => item.value != 2).toList(),
      selected: selected,
      onSelected: _selectTab,
    );
    // Preserve the tab stack when the side dock is inserted or removed.
    final tabContent = Expanded(
      key: const ValueKey('tab-content'),
      child: _AnimatedTabStack(
        index: selected,
        children: const [HomePage(), NodesPage(), RulesPage(), ToolsPage()],
      ),
    );
    return ShellScope(
      switchTab: _selectTab,
      child: Scaffold(
        extendBody: !useSideDock,
        body: SafeArea(
          top: false,
          bottom: useSideDock,
          child: Row(
            textDirection: TextDirection.ltr,
            children: [
              if (useSideDock)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Align(child: navigation),
                ),
              tabContent,
            ],
          ),
        ),
        bottomNavigationBar: useSideDock
            ? null
            : SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Align(heightFactor: 1, child: navigation),
              ),
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
  final _entries = <int, OverlayEntry>{};

  @override
  void initState() {
    super.initState();
    _entries[widget.index] = _createEntry(widget.index, initial: true);
  }

  OverlayEntry _createEntry(int index, {bool initial = false}) => OverlayEntry(
    opaque: initial,
    maintainState: true,
    builder: (context) {
      final selected = index == widget.index;
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: initial ? 1 : 0, end: selected ? 1 : 0),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        onEnd: () {
          if (index == widget.index) _entries[index]?.opaque = true;
        },
        builder: (context, value, child) =>
            Opacity(opacity: value, child: child),
        child: IgnorePointer(
          ignoring: !selected,
          child: ExcludeSemantics(
            excluding: !selected,
            child: TickerMode(
              enabled: selected,
              child: RepaintBoundary(child: widget.children[index]),
            ),
          ),
        ),
      );
    },
  );

  List<OverlayEntry> get _orderedEntries => [
    for (final entry in _entries.entries)
      if (entry.key != widget.index) entry.value,
    _entries[widget.index]!,
  ];

  @override
  void didUpdateWidget(_AnimatedTabStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      // Keep entries onstage during the fade, then let Overlay skip layout
      // of the retained pages below the opaque selected entry.
      _entries.putIfAbsent(widget.index, () => _createEntry(widget.index));
      for (final entry in _entries.values) {
        entry.opaque = false;
      }
      _overlayKey.currentState!.rearrange(_orderedEntries);
    }
    for (final entry in _entries.values) {
      entry.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    for (final entry in _entries.values) {
      entry.remove();
      entry.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Overlay(key: _overlayKey, initialEntries: _orderedEntries);
}
