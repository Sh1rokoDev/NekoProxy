import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../domain/config_policy.dart';
import '../../state/app_controller.dart';

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  late final TextEditingController _advanced;
  late final TextEditingController _custom;
  bool _customEnabled = false;
  int _tab = 0;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final controller = AppScope.read(context);
    _advanced = TextEditingController(
      text: controller.snapshot.advancedJson.isEmpty
          ? '{\n  \n}'
          : const JsonEncoder.withIndent('  ').convert(controller.snapshot.advancedJson),
    );
    _custom = TextEditingController(text: controller.snapshot.customConfig);
    _customEnabled = controller.snapshot.useCustomConfig;
  }

  @override
  void dispose() {
    _advanced.dispose();
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    return HeaderScaffold(
      title: const Text('高级配置'),
      scrollsBehindHeader: false,
      fadeTail: 8,
      body: (_) => Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 14),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Row(
                  children: [
                    Expanded(
                      child: SlidingSegmentedControl<int>(
                        width: double.infinity,
                        height: 48,
                        segments: const [
                          SlidingSegmentOption(
                            value: 0,
                            label: 'JSON 扩展',
                            icon: Icons.merge_type_rounded,
                          ),
                          SlidingSegmentOption(
                            value: 1,
                            label: '自定义配置',
                            icon: Icons.data_object_rounded,
                          ),
                        ],
                        selected: _tab,
                        onChanged: (value) => setState(() => _tab = value),
                      ),
                    ),
                    if (_tab == 0) ...[
                      const SizedBox(width: 6),
                      TextButton.icon(
                        onPressed: () => _validateJson(),
                        icon: const Icon(Icons.rule_rounded, size: 18),
                        label: const Text('校验'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: _tab == 0 ? _buildAdvanced(context, controller) : _buildCustom(context, controller),
                ),
              ),
            ),
          ),
          if (_tab == 1)
            Container(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              color: theme.colorScheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _customEnabled ? '完整配置已启用' : '启用完整配置',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Switch(
                          value: _customEnabled,
                          onChanged: controller.busy ? null : (value) => _saveCustom(controller, value),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: controller.busy ? null : () => _saveCustom(controller, _customEnabled),
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('保存并应用'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAdvanced(BuildContext context, AppController controller) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: '与生成的配置合并',
          icon: Icons.merge_rounded,
          child: Text(
            '这里填写的是 sing-box 配置 JSON。它会覆盖生成的配置中同名字段，并接受同一套安全校验；无法覆盖 TUN、监听等平台集成时，请改用完整自定义配置。',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _advanced,
          minLines: 22,
          maxLines: 34,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45),
          decoration: const InputDecoration(
            labelText: '高级 JSON 扩展',
            alignLabelWithHint: true,
            hintText: '{\n  "inbounds": [],\n  "outbounds": []\n}',
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _prettyPrint(_advanced),
                icon: const Icon(Icons.format_align_left_rounded),
                label: const Text('格式化'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: controller.busy ? null : () => _saveAdvanced(controller),
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存并应用'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCustom(BuildContext context, AppController controller) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: '使用完整的 sing-box 配置',
          icon: Icons.warning_amber_rounded,
          color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
          child: Text(
            '以原文运行；与本地监听、TUN 设置冲突时需自行调整。',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _custom,
          minLines: 24,
          maxLines: 40,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45),
          decoration: const InputDecoration(
            labelText: '完整 sing-box 配置（JSON）',
            alignLabelWithHint: true,
            hintText: '{\n  "inbounds": [],\n  "outbounds": []\n}',
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => _prettyPrint(_custom),
              icon: const Icon(Icons.format_align_left_rounded),
              label: const Text('格式化'),
            ),
            OutlinedButton.icon(
              onPressed: () => _validateCustom(),
              icon: const Icon(Icons.rule_rounded),
              label: const Text('校验'),
            ),
            OutlinedButton.icon(
              onPressed: () => _loadGenerated(controller),
              icon: const Icon(Icons.auto_fix_high_rounded),
              label: const Text('载入当前生成配置'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _saveAdvanced(AppController controller) async {
    try {
      final decoded = jsonDecode(_advanced.text);
      if (decoded is! Map) throw const FormatException('根节点必须是 JSON 对象');
      final map = Map<String, dynamic>.from(decoded);
      final violations = ConfigPolicy.validate(map);
      if (violations.isNotEmpty) {
        _showError('包含被禁止的设置：${violations.map((e) => e.message).join('；')}');
        return;
      }
      await controller.saveAdvancedJson(map);
      if (mounted) _showInfo('高级配置已保存并应用');
    } catch (e) {
      _showError('JSON 无效：$e');
    }
  }

  Future<void> _saveCustom(AppController controller, bool enabled) async {
    try {
      final violations = ConfigPolicy.validateText(_custom.text.trim());
      if (violations.isNotEmpty) {
        _showError('配置被拒绝：${violations.map((e) => e.message).join('；')}');
        return;
      }
      if (enabled && _custom.text.trim().isEmpty) {
        _showError('请先填写完整配置');
        return;
      }
      setState(() => _customEnabled = enabled);
      await controller.setCustomConfig(_custom.text, enabled);
      if (mounted) _showInfo(enabled ? '已启用完整自定义配置' : '已恢复由 NekoProxy 管理的配置');
    } catch (e) {
      _showError('$e');
    }
  }

  void _validateJson() {
    try {
      final decoded = jsonDecode(_advanced.text);
      if (decoded is! Map) throw const FormatException('根节点必须是 JSON 对象');
      final violations = ConfigPolicy.validate(Map<String, dynamic>.from(decoded));
      if (violations.isEmpty) {
        _showInfo('JSON 结构有效，且不包含被禁止的设置');
      } else {
        _showError(violations.map((e) => e.toString()).join('\n'));
      }
    } catch (e) {
      _showError('JSON 无效：$e');
    }
  }

  void _validateCustom() {
    try {
      final decoded = jsonDecode(_custom.text);
      if (decoded is! Map) throw const FormatException('根节点必须是 JSON 对象');
      final violations = ConfigPolicy.validate(Map<String, dynamic>.from(decoded));
      if (violations.isEmpty) {
        _showInfo('配置结构有效，且不包含被禁止的设置');
      } else {
        _showError(violations.map((e) => e.toString()).join('\n'));
      }
    } catch (e) {
      _showError('JSON 无效：$e');
    }
  }

  void _prettyPrint(TextEditingController controller) {
    try {
      final decoded = jsonDecode(controller.text);
      controller.text = const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (e) {
      _showError('JSON 无效：$e');
    }
  }

  Future<void> _loadGenerated(AppController controller) async {
    final previousText = _custom.text;
    try {
      final compiled = await controller.compileForExport();
      if (!mounted || _custom.text != previousText) return;
      setState(() {
        _custom.text = const JsonEncoder.withIndent('  ').convert(compiled.json);
      });
      _showInfo('已载入当前生成配置。请检查后再启用完整配置。');
    } catch (e) {
      if (!mounted) return;
      _showError('$e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 5)));
  }

  void _showInfo(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
