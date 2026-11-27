import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../app/dialogs.dart';
import '../../domain/models.dart';
import '../../services/qr_service.dart';
import '../../state/app_controller.dart';
import 'node_group_widgets.dart';
import 'wireguard_profile_editor.dart';
import 'wireguard_qr_scanner.dart';

enum _ProfileAction { test, editFields, editSource, exportFile, delete }

enum _GroupAction { rename, add, delete }

enum _QrSource { camera, image }

enum _Add { single, clipboard, file, qr }

enum _Editor { fields, source }

Future<String?> askWireGuardGroupName(
  BuildContext context, {
  String name = '',
}) => showAppDialog<String>(
  context: context,
  builder: (_) => _GroupNameDialog(name: name),
);

class WireGuardGroupCard extends StatefulWidget {
  const WireGuardGroupCard({
    super.key,
    required this.controller,
    required this.group,
    required this.profiles,
    required this.order,
    required this.reorderEnabled,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final AppController controller;
  final WireGuardGroup group;
  final List<WireGuardProfile> profiles;
  final NodeGroupOrder order;
  final bool reorderEnabled;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  @override
  State<WireGuardGroupCard> createState() => _WireGuardGroupCardState();
}

class _WireGuardGroupCardState extends State<WireGuardGroupCard> {
  bool _busy = false;
  String? _error;

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
      final profile = _newProfile(
        file.name.replaceFirst(RegExp(r'\.conf$', caseSensitive: false), ''),
        configuration,
      );
      profile.parse();
      await widget.controller.saveWireGuardProfile(profile);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Exception {
      if (mounted) setState(() => _error = '无法读取 WireGuard 配置。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  WireGuardProfile _newProfile(
    String name,
    String configuration,
  ) => WireGuardProfile(
    id: '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 31)}',
    name: name.trim().isEmpty
        ? 'WireGuard ${widget.profiles.length + 1}'
        : name,
    configuration: configuration,
    groupId: widget.group.id,
  );

  Future<void> _edit({WireGuardProfile? profile, bool raw = false}) async {
    WireGuardConfig? configuration;
    if (!raw && profile != null) {
      try {
        configuration = profile.parse();
      } on FormatException catch (error) {
        setState(() => _error = error.message);
        return;
      }
    }
    final edited = await showAppDialog<WireGuardProfile>(
      context: context,
      builder: (_) => WireGuardProfileEditor(
        profile: profile,
        configuration: configuration,
        raw: raw,
        groupId: widget.group.id,
      ),
    );
    if (!mounted || edited == null) return;
    await _run(() => widget.controller.saveWireGuardProfile(edited));
  }

  Future<void> _scanQr() async {
    setState(() => _busy = true);
    try {
      final source = Platform.isAndroid
          ? await showAppChoice<_QrSource>(
              context: context,
              title: '扫描二维码',
              options: const [
                (
                  value: _QrSource.camera,
                  icon: Icons.photo_camera_outlined,
                  label: '使用相机',
                ),
                (
                  value: _QrSource.image,
                  icon: Icons.image_outlined,
                  label: '从二维码图片导入',
                ),
              ],
            )
          : _QrSource.image;
      if (!mounted || source == null) return;

      final String? content;
      if (source == _QrSource.camera) {
        content = await Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => const WireGuardQrScanner()),
        );
        if (content == null) return;
      } else {
        final files = await FilePicker.pickFiles(
          type: FileType.image,
          dialogTitle: '选择二维码图片',
        );
        if (files.isEmpty || !mounted) return;
        final bytes = await files.single.readAsBytes();
        if (bytes.length > 16 * 1024 * 1024) {
          throw const FormatException('二维码图片超过 16 MB。');
        }
        content = await decodeQrFromImageBytes(bytes);
        if (content == null) {
          throw const FormatException('图片中没有识别到二维码。');
        }
      }
      if (!mounted) return;
      final profile = _newProfile('', content);
      await _edit(profile: profile);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Exception {
      if (mounted) setState(() => _error = '无法读取二维码。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(WireGuardProfile profile) async {
    final confirmed = await confirmDialog(
      context,
      title: '导出 WireGuard .conf',
      message: '导出的配置文件包含明文私钥和预共享密钥，请妥善保管。',
      confirmLabel: '选择保存位置',
    );
    if (!mounted || !confirmed) return;
    setState(() => _busy = true);
    try {
      final filename = profile.name.replaceAll(
        RegExp(r'[<>:"/\\|?*\x00-\x1f]'),
        '_',
      );
      final saved = await FilePicker.saveFile(
        fileName: '$filename.conf',
        bytes: Uint8List.fromList(utf8.encode(profile.configuration)),
        dialogTitle: '保存 WireGuard 配置',
      );
      if (mounted && saved != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已保存 WireGuard 配置文件。')));
      }
    } on Exception {
      if (mounted) setState(() => _error = '无法保存 WireGuard 配置文件。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (mounted) setState(() => _error = null);
    try {
      await action();
    } on Exception catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _add() async {
    final action = await showAppSheet<_Add>(
      context: context,
      title: '添加 WireGuard 节点',
      options: const [
        (value: _Add.single, icon: Icons.add_rounded, label: '单个节点'),
        (
          value: _Add.clipboard,
          icon: Icons.content_paste_rounded,
          label: '从剪贴板导入',
        ),
        (value: _Add.file, icon: Icons.file_open_outlined, label: '从文件导入'),
        (value: _Add.qr, icon: Icons.qr_code_2_rounded, label: '从二维码图片导入'),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _Add.single:
        final method = await showAppChoice<_Editor>(
          context: context,
          title: '创建 WireGuard 节点',
          options: const [
            (
              value: _Editor.source,
              icon: Icons.code_rounded,
              label: '编写 .conf',
            ),
            (
              value: _Editor.fields,
              icon: Icons.list_alt_outlined,
              label: '使用表单',
            ),
          ],
        );
        if (mounted && method != null) {
          await _edit(raw: method == _Editor.source);
        }
      case _Add.clipboard:
        try {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          if (!mounted) return;
          final content = data?.text;
          if (content == null || content.trim().isEmpty) {
            setState(() => _error = '剪贴板为空。');
            return;
          }
          await _edit(profile: _newProfile('', content));
        } on PlatformException {
          if (mounted) setState(() => _error = '无法读取剪贴板。');
        }
      case _Add.file:
        await _import();
      case _Add.qr:
        await _scanQr();
      case null:
        return;
    }
  }

  Future<bool> _confirmDelete(String title, String name) => confirmDialog(
    context,
    title: title,
    message: '删除「$name」？',
    confirmLabel: '删除',
    destructive: true,
  );

  Future<void> _groupAction(_GroupAction action) async {
    switch (action) {
      case _GroupAction.rename:
        final name = await askWireGuardGroupName(
          context,
          name: widget.group.name,
        );
        if (mounted && name != null) {
          await _run(
            () =>
                widget.controller.saveWireGuardGroup(name, id: widget.group.id),
          );
        }
      case _GroupAction.add:
        await _add();
      case _GroupAction.delete:
        if (await _confirmDelete('删除 WireGuard 分组', widget.group.name) &&
            mounted) {
          await _run(
            () => widget.controller.deleteWireGuardGroup(widget.group.id),
          );
        }
    }
  }

  Future<void> _profileAction(
    WireGuardProfile profile,
    _ProfileAction action,
  ) async {
    switch (action) {
      case _ProfileAction.test:
        widget.controller.queueWireGuardTest([profile]);
      case _ProfileAction.editFields:
        await _edit(profile: profile);
      case _ProfileAction.editSource:
        await _edit(profile: profile, raw: true);
      case _ProfileAction.exportFile:
        await _export(profile);
      case _ProfileAction.delete:
        if (await _confirmDelete('删除 WireGuard 节点', profile.name) && mounted) {
          await _run(
            () => widget.controller.deleteWireGuardProfile(profile.id),
          );
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final enabled = !_busy && !controller.busy && !controller.changingWireGuard;
    final scheme = Theme.of(context).colorScheme;
    final activeProfile = controller.activeWireGuard;
    final hasProfiles = controller.snapshot.wireGuardProfiles.any(
      (profile) => profile.groupId == widget.group.id,
    );
    final testing = widget.profiles.any(
      (profile) => controller.isWireGuardTestRequested(profile.id),
    );
    final canTest = widget.profiles.any(controller.canTestWireGuardProfile);
    final hasInactiveProfiles =
        controller.running &&
        widget.profiles.any((profile) => profile.id != activeProfile?.id);
    return NodeGroupSurface(
      active: activeProfile?.groupId == widget.group.id,
      builder: (context, hovered, onHighlightChanged) => ReorderableNodeGroup(
        order: widget.order,
        enabled: enabled && widget.reorderEnabled,
        tooltip: '拖拽调整 WireGuard 分组顺序',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NodeGroupHeader(
              title: widget.group.name,
              subtitle: 'WireGuard · ${widget.profiles.length} 节点',
              icon: Icons.vpn_key_outlined,
              expanded: widget.expanded,
              hovered: hovered,
              onToggle: widget.onToggleExpanded,
              onHighlightChanged: onHighlightChanged,
              actions: [
                NodeGroupActionButton(
                  tooltip: !hasInactiveProfiles
                      ? '测试本组 WireGuard 节点'
                      : canTest
                      ? '测试本组当前连接的 WireGuard 节点'
                      : '断开连接后可测试本组 WireGuard 节点',
                  onPressed: canTest && !testing
                      ? () => controller.queueWireGuardTest(
                          widget.profiles,
                          groupId: widget.group.id,
                        )
                      : null,
                  child: testing
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed_rounded, size: 18),
                ),
                const SizedBox(width: 2),
                PopupMenuButton<_GroupAction>(
                  tooltip: 'WireGuard 分组操作',
                  enabled: enabled,
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  menuPadding: const EdgeInsets.symmetric(vertical: 6),
                  style: nodeGroupActionStyle(
                    scheme,
                    background: false,
                    size: 32,
                  ),
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  onSelected: _groupAction,
                  itemBuilder: (_) => [
                    nodeMenuItem(
                      value: _GroupAction.rename,
                      icon: Icons.edit_outlined,
                      label: '重命名分组',
                    ),
                    if (hasProfiles)
                      nodeMenuItem(
                        value: _GroupAction.add,
                        icon: Icons.add_rounded,
                        label: '添加 WireGuard 节点',
                      ),
                    const PopupMenuDivider(height: 9),
                    nodeMenuItem(
                      value: _GroupAction.delete,
                      icon: Icons.delete_outline_rounded,
                      label: '删除分组',
                      color: scheme.error,
                    ),
                  ],
                ),
              ],
            ),
            NodeGroupBody(
              expanded: widget.expanded,
              child: widget.profiles.isEmpty
                  ? NodeGroupEmpty(
                      message: hasProfiles ? '没有匹配的节点' : '暂无节点',
                      showAdd: !hasProfiles,
                      onAdd: enabled ? _add : null,
                    )
                  : NodeGrid(
                      itemCount: widget.profiles.length,
                      itemBuilder: (context, index) {
                        final profile = widget.profiles[index];
                        return _profileTile(
                          profile,
                          current: activeProfile?.id == profile.id,
                          enabled: enabled,
                        );
                      },
                    ),
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(error, style: TextStyle(color: scheme.error)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _profileTile(
    WireGuardProfile profile, {
    required bool current,
    required bool enabled,
  }) {
    final controller = widget.controller;
    final latency = controller.wireGuardLatencyFor(profile);
    final testing = controller.isWireGuardTestRequested(profile.id);
    String address;
    try {
      address = profile.parse().firstEndpoint;
    } on FormatException {
      // Keep saved profiles with invalid configuration editable.
      address = '—';
    }
    return Semantics(
      selected: current,
      child: NodeTile(
        name: profile.name,
        protocol: 'wireguard',
        address: address,
        current: current,
        onSelect: enabled && !widget.controller.snapshot.useCustomConfig
            ? () => _run(() => widget.controller.selectWireGuard(profile.id))
            : null,
        footer: Row(
          children: [
            NodeLatency(
              delay: latency?.delay,
              error: latency?.error,
              testing: testing,
            ),
            const Spacer(),
            SizedBox(
              width: 24,
              height: 24,
              child: PopupMenuButton<_ProfileAction>(
                tooltip: '配置操作：${profile.name}',
                enabled: enabled,
                padding: EdgeInsets.zero,
                iconSize: 17,
                onSelected: (action) => _profileAction(profile, action),
                itemBuilder: (context) => [
                  nodeMenuItem(
                    value: _ProfileAction.test,
                    icon: Icons.speed_rounded,
                    label: controller.running && !current
                        ? '断开连接后可测速'
                        : '测试节点延迟',
                    enabled:
                        !testing && controller.canTestWireGuardProfile(profile),
                  ),
                  nodeMenuItem(
                    value: _ProfileAction.editFields,
                    icon: Icons.edit_outlined,
                    label: '编辑节点',
                  ),
                  nodeMenuItem(
                    value: _ProfileAction.editSource,
                    icon: Icons.code_rounded,
                    label: '编辑 .conf',
                  ),
                  nodeMenuItem(
                    value: _ProfileAction.exportFile,
                    icon: Icons.file_download_outlined,
                    label: '导出 .conf',
                  ),
                  const PopupMenuDivider(height: 9),
                  nodeMenuItem(
                    value: _ProfileAction.delete,
                    icon: Icons.delete_outline_rounded,
                    label: '删除节点',
                    color: Theme.of(context).colorScheme.error,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupNameDialog extends StatefulWidget {
  const _GroupNameDialog({required this.name});
  final String name;
  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  late final _name = TextEditingController(text: widget.name);
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Text(widget.name.isEmpty ? '创建 WireGuard 分组' : '重命名 WireGuard 分组'),
    content: TextField(
      controller: _name,
      autofocus: true,
      decoration: const InputDecoration(labelText: '分组名称'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      ValueListenableBuilder(
        valueListenable: _name,
        builder: (context, value, child) => FilledButton(
          onPressed: value.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, value.text.trim()),
          child: const Text('保存'),
        ),
      ),
    ],
  );
}
