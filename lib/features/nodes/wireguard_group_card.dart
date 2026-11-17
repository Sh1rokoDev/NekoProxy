import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../services/qr_service.dart';
import '../../state/app_controller.dart';
import 'wireguard_profile_editor.dart';
import 'wireguard_qr_scanner.dart';

enum _ProfileAction { editFields, editSource, exportFile, delete }

enum _GroupAction { rename, delete }

enum _QrSource { camera, image }

enum _Add { single, clipboard, file, qr }

enum _Editor { fields, source }

Future<String?> askWireGuardGroupName(
  BuildContext context, {
  String name = '',
}) => showDialog<String>(
  context: context,
  builder: (_) => _GroupNameDialog(name: name),
);

class WireGuardGroupCard extends StatefulWidget {
  const WireGuardGroupCard({
    super.key,
    required this.controller,
    required this.group,
    required this.profiles,
  });

  final AppController controller;
  final WireGuardGroup group;
  final List<WireGuardProfile> profiles;

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
    final edited = await showDialog<WireGuardProfile>(
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
          ? await showDialog<_QrSource>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('扫描二维码'),
                children: [
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, _QrSource.camera),
                    child: const Text('使用相机'),
                  ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, _QrSource.image),
                    child: const Text('从二维码图片导入'),
                  ),
                ],
              ),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出 WireGuard .conf'),
        content: const Text('导出的配置文件包含明文私钥和预共享密钥，请妥善保管。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('选择保存位置'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
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
    final action = await showModalBottomSheet<_Add>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (action, icon, label) in const [
              (_Add.single, Icons.add, '单个节点'),
              (_Add.clipboard, Icons.content_paste_rounded, '从剪贴板导入'),
              (_Add.file, Icons.file_open_outlined, '从文件导入'),
              (_Add.qr, Icons.qr_code_2_rounded, '从二维码图片导入'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(context, action),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _Add.single:
        final method = await showDialog<_Editor>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('创建 WireGuard 节点'),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, _Editor.source),
                child: const Text('编写 .conf'),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, _Editor.fields),
                child: const Text('使用表单'),
              ),
            ],
          ),
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

  Future<bool> _confirmDelete(String name) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('删除 $name？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;

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
      case _GroupAction.delete:
        if (await _confirmDelete(widget.group.name) && mounted) {
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
      case _ProfileAction.editFields:
        await _edit(profile: profile);
      case _ProfileAction.editSource:
        await _edit(profile: profile, raw: true);
      case _ProfileAction.exportFile:
        await _export(profile);
      case _ProfileAction.delete:
        if (await _confirmDelete(profile.name) && mounted) {
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
    return SectionCard(
      title: widget.group.name,
      icon: Icons.vpn_key_outlined,
      trailing: PopupMenuButton<_GroupAction>(
        tooltip: 'WireGuard 分组操作',
        enabled: enabled,
        onSelected: _groupAction,
        itemBuilder: (_) => const [
          PopupMenuItem(value: _GroupAction.rename, child: Text('重命名分组')),
          PopupMenuItem(value: _GroupAction.delete, child: Text('删除分组')),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          if (widget.profiles.isEmpty) const Text('暂无 WireGuard 节点'),
          for (final profile in widget.profiles)
            Material(
              type: MaterialType.transparency,
              child: ListTile(
                title: Text(profile.name),
                selected: controller.activeWireGuard?.id == profile.id,
                selectedTileColor: scheme.secondaryContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                leading: Icon(
                  controller.activeWireGuard?.id == profile.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                onTap: enabled && !controller.snapshot.useCustomConfig
                    ? () => _run(() => controller.selectWireGuard(profile.id))
                    : null,
                trailing: PopupMenuButton<_ProfileAction>(
                  tooltip: '配置操作：${profile.name}',
                  enabled: enabled,
                  onSelected: (action) => _profileAction(profile, action),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: _ProfileAction.editFields,
                      child: Text('编辑节点'),
                    ),
                    PopupMenuItem(
                      value: _ProfileAction.editSource,
                      child: Text('编辑 .conf'),
                    ),
                    PopupMenuItem(
                      value: _ProfileAction.exportFile,
                      child: Text('导出 .conf'),
                    ),
                    PopupMenuItem(
                      value: _ProfileAction.delete,
                      child: Text('删除节点'),
                    ),
                  ],
                ),
              ),
            ),
          OutlinedButton.icon(
            onPressed: enabled ? _add : null,
            icon: const Icon(Icons.add),
            label: const Text('添加 WireGuard 节点'),
          ),
          if (_error case final error?)
            Text(error, style: TextStyle(color: scheme.error)),
        ],
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
  Widget build(BuildContext context) => AlertDialog(
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
