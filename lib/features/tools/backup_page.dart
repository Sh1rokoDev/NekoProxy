import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../services/backup_service.dart';
import '../../state/app_controller.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final _password = TextEditingController();
  bool _working = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    return HeaderScaffold(
      title: const Text('备份与恢复'),
      body: (headerInset) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, headerInset + 24, 24, 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionCard(
                  title: '备份密码',
                  icon: Icons.lock_outline_rounded,
                  child: TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText:
                          controller.snapshot.wireGuardProfiles.isNotEmpty
                          ? '密码（导出 WireGuard 配置时必填）'
                          : '密码（可选）',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: '导出与恢复',
                  icon: Icons.settings_backup_restore_rounded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: _working ? null : () => _export(controller),
                        icon: _working
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_alt_rounded),
                        label: const Text('导出备份文件'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _working ? null : () => _import(controller),
                        icon: const Icon(Icons.file_open_outlined),
                        label: const Text('选择备份文件并恢复'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: '重置',
                  icon: Icons.delete_forever_outlined,
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        onPressed: _working ? null : () => _reset(controller),
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text('重置所有数据'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _export(AppController controller) async {
    setState(() => _working = true);
    try {
      final password = _password.text.isEmpty ? null : _password.text;
      if (Platform.isWindows) {
        final path = await controller.exportLocalBackup(password: password);
        if (mounted) _message('备份已保存到 $path');
        return;
      }
      final content = await controller.exportBackup(password: password);
      final now = DateTime.now();
      final filename =
          'nekoproxy-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.json';
      final result = await FilePicker.saveFile(
        fileName: filename,
        bytes: Uint8List.fromList(utf8.encode(content)),
        mimeType: 'application/json',
        dialogTitle: '保存 NekoProxy 备份',
      );
      if (mounted) {
        _message(result == null ? '已取消保存' : '备份已保存');
      }
    } catch (e) {
      if (mounted) _message('导出失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _import(AppController controller) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final picked = await FilePicker.pickFiles();
      if (picked.isEmpty || !mounted) return;
      final content = utf8.decode(await picked.first.readAsBytes());
      if (!mounted) return;
      var password = _password.text.isEmpty ? null : _password.text;
      while (mounted) {
        try {
          await controller.importBackup(content, password: password);
          if (mounted) _message('备份已恢复');
          return;
        } on BackupPasswordException catch (error) {
          if (!mounted) return;
          password = await _promptBackupPassword(error.message);
          if (password == null) return;
        }
      }
    } catch (e) {
      if (mounted) _message('恢复失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String?> _promptBackupPassword(String message) {
    var password = '';
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            if (password.isNotEmpty) Navigator.of(context).pop(password);
          }

          return AlertDialog(
            scrollable: true,
            title: const Text('输入备份密码'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(message),
                const SizedBox(height: 12),
                TextField(
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '备份密码'),
                  onChanged: (value) => setDialogState(() => password = value),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: password.isEmpty ? null : submit,
                child: const Text('恢复'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _reset(AppController controller) async {
    final confirmed = await confirmDialog(
      context,
      title: '重置所有数据',
      message: '订阅、节点、规则和设置都会被删除，且无法恢复。',
      confirmLabel: '重置',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _working = true);
    try {
      await controller.resetAll();
      if (mounted) _message('已重置');
    } catch (e) {
      if (mounted) _message('重置失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _message(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}
