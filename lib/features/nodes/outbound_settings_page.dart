import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';

class OutboundSettingsPage extends StatefulWidget {
  const OutboundSettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<OutboundSettingsPage> createState() => _OutboundSettingsPageState();
}

class _OutboundSettingsPageState extends State<OutboundSettingsPage> {
  static const _labels = {
    OutboundMode.proxy: '仅代理',
    OutboundMode.wireGuard: '仅 WireGuard',
    OutboundMode.wireGuardProxy: 'WireGuard + 代理',
  };
  late OutboundMode _mode = widget.controller.snapshot.outboundMode;
  late String? _selected = widget.controller.snapshot.wireGuardProfileId;
  late final _profiles = List.of(widget.controller.snapshot.wireGuardProfiles);
  bool _busy = false;
  String? _error;

  WireGuardProfile? get _profile {
    for (final profile in _profiles) {
      if (profile.id == _selected) return profile;
    }
    return null;
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['conf'],
      );
      if (files.isEmpty || !mounted) return;
      final file = files.single;
      final bytes = await file.readAsBytes();
      if (bytes.length > 256 * 1024) {
        throw const FormatException('WireGuard 配置文件超过 256 KB');
      }
      final configuration = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      final profile = WireGuardProfile(
        id: '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 31)}',
        name: file.name.replaceFirst(
          RegExp(r'\.conf$', caseSensitive: false),
          '',
        ),
        configuration: configuration,
      );
      profile.parse();
      setState(() {
        _profiles.add(profile);
        _selected = profile.id;
        _error = null;
      });
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Exception {
      if (mounted) setState(() => _error = '无法读取 WireGuard 配置。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(WireGuardProfile profile) async {
    final edited = await showDialog<WireGuardProfile>(
      context: context,
      builder: (_) => _ProfileEditor(profile: profile),
    );
    if (!mounted || edited == null) return;
    setState(() {
      _profiles[_profiles.indexOf(profile)] = edited;
      _error = null;
    });
  }

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.applyOutboundSettings(
        _mode,
        _selected,
        _profiles,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final profile = _profile;
    final active = _mode != OutboundMode.proxy;
    bool protected = false;
    try {
      protected =
          Platform.isWindows &&
          active &&
          (profile?.parse().windowsProtection ?? false);
    } on FormatException {
      // Applying the draft reports the invalid profile without closing the page.
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final explanation = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return HeaderScaffold(
      title: const Text('高级'),
      body: (headerInset) => ListView(
        padding: EdgeInsets.fromLTRB(24, headerInset + 24, 24, 24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: HeaderScaffold.defaultContentWidth,
              ),
              child: controller.snapshot.useCustomConfig
                  ? const EmptyState(
                      icon: Icons.data_object_rounded,
                      title: '出站由自定义配置接管',
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 16,
                      children: [
                        SectionCard(
                          title: '出站模式',
                          icon: Icons.route_outlined,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 12,
                            children: [
                              DropdownButtonFormField<OutboundMode>(
                                initialValue: _mode,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '模式',
                                ),
                                items: [
                                  for (final item in _labels.entries)
                                    DropdownMenuItem(
                                      value: item.key,
                                      child: Text(
                                        item.value,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: _busy
                                    ? null
                                    : (value) {
                                        if (value != null) {
                                          setState(() => _mode = value);
                                        }
                                      },
                              ),
                              Text(switch (_mode) {
                                OutboundMode.proxy => '按现有规则直连、代理或拦截',
                                OutboundMode.wireGuard =>
                                  '匹配的地址 → WireGuard → 目标地址',
                                OutboundMode.wireGuardProxy => '直连 → WireGuard → 目标地址\n代理 → WireGuard → 代理节点 → 目标地址\n拦截 → 拒绝连接',
                              }, style: explanation),
                              if (protected)
                                Row(
                                  children: [
                                    Icon(
                                      Icons.shield_outlined,
                                      size: 18,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '在 Windows 上启用 TUN 和系统断网保护',
                                        style: explanation,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                        SectionCard(
                          title: 'WireGuard 节点',
                          icon: Icons.vpn_key_outlined,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 8,
                            children: [
                              if (_profiles.isEmpty)
                                Text('尚未导入 WireGuard 配置', style: explanation),
                              for (final item in _profiles)
                                Material(
                                  type: MaterialType.transparency,
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    selected: item.id == _selected,
                                    selectedTileColor: scheme.surfaceContainer,
                                    leading: Icon(
                                      item.id == _selected
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_off,
                                      size: 18,
                                    ),
                                    title: Text(item.name),
                                    onTap: _busy
                                        ? null
                                        : () => setState(
                                            () => _selected = item.id,
                                          ),
                                    trailing: HeaderIconButton(
                                      tooltip: '编辑 ${item.name}',
                                      onPressed: _busy
                                          ? null
                                          : () => _edit(item),
                                      icon: Icons.edit_outlined,
                                    ),
                                  ),
                                ),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: OutlinedButton.icon(
                                  onPressed: _busy ? null : _import,
                                  icon: const Icon(Icons.file_upload_outlined),
                                  label: const Text('导入 .conf'),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_error case final error?)
                          Text(error, style: TextStyle(color: scheme.error)),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: FilledButton(
                            onPressed: _busy || controller.busy ? null : _apply,
                            child: Text(
                              controller.outboundChangeNeedsRestart(
                                    _mode,
                                    profile,
                                  )
                                  ? '应用并重新连接'
                                  : '应用出站设置',
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({required this.profile});
  final WireGuardProfile profile;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final _name = TextEditingController(text: widget.profile.name);
  late final _configuration = TextEditingController(
    text: widget.profile.configuration,
  );
  bool _showConfig = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _configuration.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑 WireGuard 节点'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: '名称'),
        ),
        if (_showConfig)
          TextField(
            controller: _configuration,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(labelText: 'WireGuard 配置'),
          )
        else
          TextButton(
            onPressed: () => setState(() => _showConfig = true),
            child: const Text('显示并编辑配置（含密钥）'),
          ),
        if (_error != null) Text(_error ?? ''),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存到草稿')),
    ],
  );

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入配置名称。');
      return;
    }
    final profile = WireGuardProfile(
      id: widget.profile.id,
      name: name,
      configuration: _configuration.text,
    );
    try {
      profile.parse();
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    Navigator.pop(context, profile);
  }
}
