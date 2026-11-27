import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../app/dialogs.dart';
import '../../app/theme.dart';
import '../../domain/models.dart';
import '../../runtime/runtime_client.dart';
import '../../state/app_controller.dart';

Future<List<String>?> pickInstalledApps(
  BuildContext context,
  AppController controller,
  List<String> selected,
) => showAppDialog<List<String>>(
  context: context,
  builder: (_) =>
      _InstalledAppsDialog(controller: controller, selected: selected),
);

Future<void> showVpnAppFilter(BuildContext context, AppController controller) =>
    showAppDialog<void>(
      context: context,
      builder: (_) => _InstalledAppsDialog(
        controller: controller,
        selected: controller.settings.perAppPackages,
        vpnMode: controller.settings.perAppMode,
      ),
    );

class _InstalledAppsDialog extends StatefulWidget {
  const _InstalledAppsDialog({
    required this.controller,
    required this.selected,
    this.vpnMode,
  });

  final AppController controller;
  final List<String> selected;
  final PerAppMode? vpnMode;

  @override
  State<_InstalledAppsDialog> createState() => _InstalledAppsDialogState();
}

class _InstalledAppsDialogState extends State<_InstalledAppsDialog> {
  static const _iconSize = 32.0;
  static const _iconCacheLimit = 128;

  final _icons = <(String, int), Future<Uint8List?>>{};
  late final _selected = widget.selected.toSet();
  late var _mode = widget.vpnMode;
  List<InstalledApp>? _apps;
  String _query = '';
  String? _loadError;
  String? _saveError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final apps = await widget.controller.installedApps();
      if (mounted) setState(() => _apps = apps);
    } catch (error) {
      final message = error is PlatformException ? error.message : null;
      if (mounted) setState(() => _loadError = '读取应用列表失败：${message ?? error}');
    }
  }

  Future<Uint8List?> _appIcon(String packageName, int size) {
    // Move hits to the end so scrolling only retains recently used icons.
    final key = (packageName, size);
    final icon =
        _icons.remove(key) ??
        widget.controller.installedAppIcon(packageName, size);
    _icons[key] = icon;
    if (_icons.length > _iconCacheLimit) _icons.remove(_icons.keys.first);
    return icon;
  }

  void _toggle(String packageName) {
    if (!_selected.remove(packageName)) _selected.add(packageName);
  }

  Future<void> _saveFilter({bool reconnect = false}) async {
    final mode = _mode;
    if (_saving || mode == null) return;
    final controller = widget.controller;
    if (!controller.canChangeTakeover) {
      setState(() => _saveError = '正在应用接管设置，请稍后重试。');
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await controller.updatePerApp(mode, _selected.toList());
      if (reconnect && controller.running) await controller.restartCore();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() => _saveError = '无法应用设置，请重试。');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apps = (_apps ?? const <InstalledApp>[]).where((app) {
      return app.label.toLowerCase().contains(_query) ||
          app.packageName.toLowerCase().contains(_query);
    }).toList();
    final filter = _mode != null;
    final canSelect = !_saving && _mode != PerAppMode.off;
    final missingRequiredApps = _mode == PerAppMode.allow && _selected.isEmpty;
    final canSave = !_saving && !missingRequiredApps;
    final iconPixels = (_iconSize * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 128);
    return PopScope(
      canPop: !_saving,
      child: AppDialog(
        size: AppDialogSize.standard,
        scrollContent: false,
        canClose: !_saving,
        title: Text(filter ? '应用过滤' : '选择应用'),
        content: SizedBox(
          height: 440,
          child: CustomScrollView(
            slivers: [
              // Outlined field labels float above the top edge of the field.
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.textScalerOf(context).scale(10),
                ),
              ),
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    if (filter)
                      DropdownButtonFormField<PerAppMode>(
                        borderRadius: appMenuRadius,
                        dropdownColor: Theme.of(context).popupMenuTheme.color,
                        initialValue: _mode,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'VPN 接管范围',
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: PerAppMode.off,
                            child: Text('代理全部'),
                          ),
                          DropdownMenuItem(
                            value: PerAppMode.allow,
                            child: Text('代理所选'),
                          ),
                          DropdownMenuItem(
                            value: PerAppMode.block,
                            child: Text('排除所选'),
                          ),
                        ],
                        onChanged: _saving
                            ? null
                            : (mode) => setState(() => _mode = mode),
                      ),
                    TextField(
                      enabled: !_saving,
                      onChanged: (value) =>
                          setState(() => _query = value.trim().toLowerCase()),
                      decoration: const InputDecoration(
                        labelText: '搜索应用名或包名',
                        prefixIcon: Icon(Icons.search_rounded),
                        isDense: true,
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              OutlinedButton(
                                onPressed: canSelect && apps.isNotEmpty
                                    ? () => setState(
                                        () => _selected.addAll(
                                          apps.map((app) => app.packageName),
                                        ),
                                      )
                                    : null,
                                child: Text(_query.isEmpty ? '全选' : '全选结果'),
                              ),
                              OutlinedButton(
                                onPressed: canSelect && apps.isNotEmpty
                                    ? () => setState(() {
                                        for (final app in apps) {
                                          _toggle(app.packageName);
                                        }
                                      })
                                    : null,
                                child: Text(_query.isEmpty ? '反选' : '反选结果'),
                              ),
                            ],
                          ),
                        ),
                        if (canSelect) ...[
                          const SizedBox(width: 8),
                          Text('已选 ${_selected.length} 个'),
                        ],
                      ],
                    ),
                    if (missingRequiredApps)
                      Text(
                        '至少选择一个应用，否则无法连接。',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    if (_saveError case final error?)
                      Text(
                        error,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
              switch ((_loadError, _apps, apps.isEmpty)) {
                (final error?, _, _) => SliverToBoxAdapter(
                  child: Column(
                    children: [
                      Text(error),
                      TextButton(
                        onPressed: () {
                          setState(() => _loadError = null);
                          _load();
                        },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
                (_, null, _) => const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                ),
                (_, _, true) => SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(_query.isEmpty ? '没有读取到可启动的应用。' : '没有匹配的应用'),
                  ),
                ),
                _ => SliverList.separated(
                  itemCount: apps.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final app = apps[index];
                    final selected = _selected.contains(app.packageName);
                    return CheckboxListTile(
                      key: ValueKey(app.packageName),
                      dense: true,
                      selected: selected,
                      selectedTileColor: theme.colorScheme.primary.withValues(
                        alpha: 0.08,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: appMenuRadius,
                      ),
                      value: selected,
                      onChanged: canSelect
                          ? (_) => setState(() => _toggle(app.packageName))
                          : null,
                      secondary: _buildIcon(app, iconPixels),
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
              },
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          if (filter && widget.controller.running)
            TextButton(
              onPressed: canSave ? () => _saveFilter(reconnect: true) : null,
              child: const Text('保存并重新连接'),
            ),
          FilledButton(
            onPressed: canSave
                ? filter
                      ? _saveFilter
                      : () => Navigator.pop(context, _selected.toList())
                : null,
            child: Text(filter ? '保存' : '确定'),
          ),
        ],
      ),
    );
  }

  Widget _buildIcon(InstalledApp app, int iconPixels) {
    final theme = Theme.of(context);
    final fallback = CircleAvatar(
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      child: Text(
        app.label.isEmpty ? '?' : app.label.characters.first.toUpperCase(),
        style: theme.textTheme.labelMedium,
      ),
    );
    return SizedBox.square(
      dimension: _iconSize,
      child: FutureBuilder<Uint8List?>(
        future: _appIcon(app.packageName, iconPixels),
        builder: (context, snapshot) {
          final icon = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done ||
              icon == null ||
              icon.isEmpty) {
            return fallback;
          }
          return Image.memory(
            icon,
            excludeFromSemantics: true,
            frameBuilder: (_, child, frame, _) =>
                frame == null ? fallback : child,
            errorBuilder: (_, _, _) => fallback,
          );
        },
      ),
    );
  }
}
