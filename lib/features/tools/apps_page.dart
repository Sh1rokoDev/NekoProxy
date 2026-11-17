import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../runtime/runtime_client.dart';
import '../../state/app_controller.dart';

class AppsPage extends StatefulWidget {
  const AppsPage({super.key});

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  final _search = TextEditingController();
  AppController? _controller;
  List<InstalledApp>? _apps;
  Set<String> _selected = {};
  String? _error;
  bool _loading = true;
  bool _reconnecting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final controller = AppScope.of(context);
    _controller = controller;
    _selected = controller.settings.perAppPackages.toSet();
    _load(controller);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(AppController controller) async {
    try {
      final apps = await controller.installedApps();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loading = false;
        _error = apps.isEmpty ? '没有读取到可启动的应用。' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取应用列表失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    final theme = Theme.of(context);
    final mode = controller.settings.perAppMode;
    final query = _search.text.trim().toLowerCase();
    final apps = (_apps ?? const <InstalledApp>[])
        .where(
          (app) =>
              query.isEmpty ||
              app.label.toLowerCase().contains(query) ||
              app.packageName.toLowerCase().contains(query),
        )
        .toList();

    return HeaderScaffold(
      title: const Text('分应用代理'),
      maxContentWidth: 760,
      actions: [
        if (controller.running)
          FilledButton.tonalIcon(
            onPressed: _reconnecting ? null : () => _reconnect(controller),
            icon: _reconnecting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('重新连接'),
          ),
      ],
      scrollsBehindHeader: false,
      fadeTail: 12,
      body: (_) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: SectionCard(
                  title: '接管范围',
                  icon: Icons.apps_rounded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SlidingSegmentedControl<PerAppMode>(
                        width: double.infinity,
                        height: 48,
                        segments: const [
                          SlidingSegmentOption(
                            value: PerAppMode.off,
                            label: '全部应用',
                          ),
                          SlidingSegmentOption(
                            value: PerAppMode.allow,
                            label: '仅所选',
                          ),
                          SlidingSegmentOption(
                            value: PerAppMode.block,
                            label: '排除所选',
                          ),
                        ],
                        selected: mode,
                        onChanged: (value) => _setMode(controller, value),
                      ),
                      if (mode == PerAppMode.allow && _selected.isEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '至少选择一个应用，否则无法连接。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '已选 ${_selected.length} 个',
                        style: theme.textTheme.labelMedium,
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: '搜索应用名称或包名',
                    isDense: true,
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: EmptyState(
                          icon: Icons.error_outline_rounded,
                          title: '无法列出应用',
                          message: _error!,
                          action: OutlinedButton.icon(
                            onPressed: () {
                              setState(() {
                                _loading = true;
                                _error = null;
                              });
                              _load(controller);
                            },
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('重试'),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        itemCount: apps.length,
                        itemBuilder: (context, index) {
                          final app = apps[index];
                          final checked = _selected.contains(app.packageName);
                          return CheckboxListTile(
                            dense: true,
                            value: checked,
                            onChanged: mode == PerAppMode.off
                                ? null
                                : (value) => _toggle(
                                    controller,
                                    app.packageName,
                                    value == true,
                                  ),
                            secondary: CircleAvatar(
                              radius: 16,
                              backgroundColor:
                                  theme.colorScheme.surfaceContainerHighest,
                              child: Text(
                                app.label.isEmpty
                                    ? '?'
                                    : app.label.substring(0, 1).toUpperCase(),
                                style: theme.textTheme.labelMedium,
                              ),
                            ),
                            title: Text(
                              app.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              app.system
                                  ? '${app.packageName} · 系统应用'
                                  : app.packageName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _setMode(AppController controller, PerAppMode mode) {
    if (controller.settings.perAppMode == mode) return;
    controller.updatePerApp(mode, _selected.toList());
    setState(() {});
  }

  void _toggle(AppController controller, String packageName, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(packageName);
      } else {
        _selected.remove(packageName);
      }
    });
    controller.updatePerApp(controller.settings.perAppMode, _selected.toList());
  }

  Future<void> _reconnect(AppController controller) async {
    setState(() => _reconnecting = true);
    try {
      await controller.restartCore();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(controller.running ? '已重新连接并应用接管范围' : '当前未连接，设置已保存'),
        ),
      );
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
  }
}
