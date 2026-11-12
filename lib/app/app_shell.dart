import 'package:flutter/material.dart';

import '../features/home/home_page.dart';
import '../features/nodes/nodes_page.dart';
import '../features/rules/rules_page.dart';
import '../features/tools/connections_page.dart';
import '../features/tools/tools_page.dart';
import '../state/app_controller.dart';
import 'app_scope.dart';

const _destinations = <({String label, IconData icon, IconData selectedIcon})>[
  (label: '首页', icon: Icons.home_outlined, selectedIcon: Icons.home_rounded),
  (label: '节点', icon: Icons.dns_outlined, selectedIcon: Icons.dns_rounded),
  (label: '规则', icon: Icons.rule_outlined, selectedIcon: Icons.rule_rounded),
  (label: '更多', icon: Icons.more_horiz_rounded, selectedIcon: Icons.more_horiz_rounded),
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
        ValueListenableBuilder<int>(
          valueListenable: _controller!.liveTick,
          builder: (_, _, _) => HomePage(),
        ),
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
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionsPage()));
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
          final content = DecoratedBox(
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
            child: _AnimatedTabStack(index: _index, children: _pages),
          );
          if (!desktop) {
            return Scaffold(
              body: SafeArea(bottom: false, child: content),
              bottomNavigationBar: NavigationBar(
                selectedIndex: _index,
                onDestinationSelected: _selectTab,
                destinations: [
                  for (final item in _destinations)
                    NavigationDestination(
                      icon: Icon(item.icon),
                      selectedIcon: Icon(item.selectedIcon),
                      label: item.label,
                    ),
                ],
              ),
            );
          }
          return Scaffold(
            body: Row(
              children: [
                _SideBar(
                  index: _index,
                  onSelect: _selectTab,
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AnimatedTabStack extends StatelessWidget {
  const _AnimatedTabStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < children.length; i++)
          AnimatedOpacity(
            opacity: i == index ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedScale(
              scale: i == index ? 1 : 0.99,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: IgnorePointer(
                ignoring: i != index,
                child: ExcludeSemantics(
                  excluding: i != index,
                  child: TickerMode(
                    enabled: i == index,
                    child: RepaintBoundary(child: children[i]),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SideBar extends StatelessWidget {
  const _SideBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 236,
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 18, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _destinations.length; i++)
                _SidebarItem(
                  label: _destinations[i].label,
                  icon: _destinations[i].icon,
                  selectedIcon: _destinations[i].selectedIcon,
                  selected: index == i,
                  onTap: () => onSelect(i),
                ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Icon(
                  selected ? selectedIcon : icon,
                  size: 21,
                  color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
