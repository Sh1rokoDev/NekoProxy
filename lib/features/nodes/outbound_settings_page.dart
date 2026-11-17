import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('高级')),
      body: controller.snapshot.useCustomConfig
          ? const Center(child: Text('当前出站由完整自定义配置接管。'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<OutboundMode>(
                  initialValue: _mode,
                  decoration: const InputDecoration(labelText: '出站模式'),
                  items: [
                    for (final item in _labels.entries)
                      DropdownMenuItem(
                        value: item.key,
                        child: Text(item.value),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value != null) setState(() => _mode = value);
                        },
                ),
                const SizedBox(height: 12),
                Text(switch (_mode) {
                  OutboundMode.proxy => '按现有规则直连、代理或拦截。',
                  OutboundMode.wireGuard => '匹配的地址 → WireGuard → 目标地址',
                  OutboundMode.wireGuardProxy => '直连 → WireGuard → 目标地址\n代理 → WireGuard → 代理节点 → 目标地址\n拦截 → 拒绝连接',
                }),
                if (protected)
                  const ListTile(
                    leading: Icon(Icons.shield_outlined),
                    title: Text('在 Windows 上启用 TUN 和系统断网保护。'),
                  ),
                const Divider(height: 32),
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'WireGuard 节点',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _import,
                      icon: const Icon(Icons.file_upload_outlined),
                      label: const Text('导入 .conf'),
                    ),
                  ],
                ),
                if (_profiles.isEmpty)
                  const ListTile(title: Text('尚未导入 WireGuard 配置')),
                for (final item in _profiles)
                  ListTile(
                    selected: item.id == _selected,
                    leading: Icon(
                      item.id == _selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    title: Text(item.name),
                    onTap: _busy
                        ? null
                        : () => setState(() => _selected = item.id),
                    trailing: IconButton(
                      tooltip: '编辑 ${item.name}',
                      onPressed: _busy ? null : () => _edit(item),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ),
                if (_error != null)
                  Text(
                    _error ?? '',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _busy || controller.busy ? null : _apply,
                    child: Text(
                      controller.outboundChangeNeedsRestart(_mode, profile)
                          ? '应用并重新连接'
                          : '应用出站设置',
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
